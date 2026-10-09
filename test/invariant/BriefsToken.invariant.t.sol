// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BriefsToken} from "../../src/BriefsToken.sol";
import {BriefsTokenHandler} from "./BriefsTokenHandler.sol";

/// @notice Invariants over random call sequences against `BriefsToken`.
/// @dev The token keeps balances and allowances for every holder, so what it owes (the sum of
///      balances) must always equal the fixed supply, every balance must equal what the ledger says
///      was moved to it, and no call sequence may grow, shrink or relocate the supply by any route
///      other than a holder's own transfer or allowance.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract BriefsTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant ACTOR_COUNT = 6;

    BriefsToken internal token;
    BriefsTokenHandler internal handler;
    address internal deployer = makeAddr("deployer");
    bytes32 internal codehashAtDeployment;

    function setUp() public {
        vm.prank(deployer);
        token = new BriefsToken();
        codehashAtDeployment = address(token).codehash;

        // The deployer is actor 0 and keeps most of the supply; the others start with uneven
        // grants so the first calls of a sequence already have balances to work with.
        address[] memory actors = new address[](ACTOR_COUNT);
        actors[0] = deployer;
        for (uint256 i = 1; i < ACTOR_COUNT; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            vm.prank(deployer);
            token.transfer(actors[i], (EXPECTED_SUPPLY / 100) * i);
        }

        handler = new BriefsTokenHandler(token, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.transferExceedingBalance.selector;
        selectors[4] = handler.transferToZeroAddress.selector;
        selectors[5] = handler.transferFromExceedingAllowance.selector;
        selectors[6] = handler.transferFromExceedingBalance.selector;
        selectors[7] = handler.callForeignSelector.selector;
        selectors[8] = handler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ---------------------------------------------------------------------------------------------
    // Supply conservation
    // ---------------------------------------------------------------------------------------------

    /// @notice The supply is minted once and can never grow or shrink.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "total supply changed");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY(), "total supply disagrees with the constant");
    }

    /// @notice What the token owes its holders equals what exists: every unit is held by an actor.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "sum of balances != total supply");
    }

    /// @notice Each balance equals the ledger built from the amounts the calls asked to move, so
    ///         transfers move exactly what they say: no fee, no reflection, no rounding, no leak.
    function invariant_balancesMatchGhostLedger() public view {
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.ghostBalance(actor), "balance diverged from the ledger");
        }
    }

    /// @notice Every allowance reads exactly what the owner last set, less what was spent.
    function invariant_allowancesMatchGhostLedger() public view {
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            address owner = handler.actors(i);
            for (uint256 j = 0; j < ACTOR_COUNT; j++) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance diverged from the ledger"
                );
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Nothing leaks to places that cannot act
    // ---------------------------------------------------------------------------------------------

    /// @notice No sequence parks value where no actor can recover it, and the token takes no ether.
    function invariant_nothingStrandedOrHeldByTheToken() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds a balance");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own supply");
        assertEq(token.balanceOf(address(handler)), 0, "the handler received tokens");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @notice The runtime is immutable: no sequence replaces or destroys the code.
    function invariant_codeUnchanged() public view {
        assertEq(address(token).codehash, codehashAtDeployment, "runtime code changed");
        assertGt(address(token).code.length, 0, "runtime code is gone");
    }

    /// @notice Metadata does not depend on state.
    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Briefs");
        assertEq(token.symbol(), "BRIEFS");
        assertEq(token.decimals(), 18);
    }

    // ---------------------------------------------------------------------------------------------
    // Guard against a vacuous run
    // ---------------------------------------------------------------------------------------------

    /// @dev Runs after each sequence. With nine selectors and a depth of 100 a sequence that never
    ///      reached a successful transfer or a checked revert is astronomically unlikely, so this
    ///      catches a harness that silently stopped driving the token rather than a lucky draw.
    function afterInvariant() public view {
        assertGt(handler.successfulTransfers() + handler.successfulTransferFroms(), 0, "no transfer succeeded");
        assertGt(handler.revertsObserved(), 0, "no failure path was exercised");
        assertGt(handler.rejectedForeignCalls() + handler.rejectedEtherDeposits(), 0, "no foreign call probed");
    }
}
