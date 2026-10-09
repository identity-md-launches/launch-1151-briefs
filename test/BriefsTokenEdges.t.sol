// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BriefsToken} from "../src/BriefsToken.sol";

/// @notice Edge cases and stateless properties for `BriefsToken`, complementing the unit tests in
///         `BriefsToken.t.sol`: the inputs an author does not think of (zero, one wei, the whole
///         supply, the maximum, the same call twice, self as counterparty, the zero address as
///         sender) and algebraic properties (round-trip, additivity, idempotence) fuzzed over the
///         whole input domain with `bound` rather than `vm.assume`.
/// forge-config: default.fuzz.runs = 1000
contract BriefsTokenEdgesTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant MAX = type(uint256).max;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    BriefsToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new BriefsToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment and launch-manifest constraints
    // ---------------------------------------------------------------------------------------------

    /// @dev The factory records the Solidity identifier as 32 bytes; a longer one cannot be launched.
    function test_contractIdentifierFitsTheManifest() public pure {
        string memory identifier = type(BriefsToken).name;
        assertEq(identifier, "BriefsToken");
        assertLe(bytes(identifier).length, 32, "contract identifier exceeds 32 bytes");
    }

    /// @dev No constructor arguments: the bare creation code deploys through CREATE as well as CREATE2.
    function test_bareCreationCodeDeploysThroughCreate() public {
        bytes memory code = type(BriefsToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0), "create failed");
        assertEq(BriefsToken(deployed).balanceOf(address(this)), EXPECTED_SUPPLY);
        assertEq(BriefsToken(deployed).totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev No immutables and no constructor input: the deployed runtime is the compiled runtime, so
    ///      what the launch attests is byte-for-byte what every deployment runs.
    function test_runtimeEqualsCompiledRuntime() public view {
        assertEq(address(token).code, type(BriefsToken).runtimeCode);
    }

    /// @dev Two deployments are independent: each mints a fresh supply to its own deployer and
    ///      neither can see the other's balances.
    function test_secondDeploymentDoesNotTouchTheFirst() public {
        vm.prank(alice);
        BriefsToken second = new BriefsToken();
        assertEq(second.totalSupply(), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    /// @dev The whole supply must fit the accounting types the launch flows use: Uniswap v4's
    ///      BalanceDelta is int128 per currency and liquidity is uint128.
    function test_supplyFitsPoolManagerAccounting() public view {
        assertLe(token.totalSupply(), uint256(uint128(type(int128).max)), "supply exceeds int128");
        assertLe(token.totalSupply(), uint256(type(uint96).max), "supply exceeds uint96");
    }

    /// @dev Exactly one Transfer and nothing else is emitted during construction.
    function test_constructorEmitsExactlyOneEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        BriefsToken fresh = new BriefsToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "constructor emitted more than one event");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(0)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), EXPECTED_SUPPLY);
    }

    function testFuzz_nonDeployerStartsWithNothing(address account) public view {
        if (account == deployer) return;
        assertEq(token.balanceOf(account), 0);
    }

    function testFuzz_noAllowanceExistsBeforeApproval(address owner, address spender) public view {
        assertEq(token.allowance(owner, spender), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers at the edges
    // ---------------------------------------------------------------------------------------------

    function test_transferOneWei() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 1);
    }

    function test_transferOneWeiMoreThanSupplyReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        token.transfer(alice, EXPECTED_SUPPLY + 1);
    }

    function test_transferMaxUintReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, MAX)
        );
        token.transfer(alice, MAX);
    }

    /// @dev Sending to oneself must leave the balance unchanged (no double-count, no double-debit).
    function testFuzz_selfTransferIsIdentity(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(deployer, deployer, amount);
        assertTrue(token.transfer(deployer, amount));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_selfTransferBeyondBalanceReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        token.transfer(deployer, EXPECTED_SUPPLY + 1);
    }

    /// @dev Zero-address receiver is refused before the balance is consulted: even a sender with
    ///      nothing, sending nothing, is refused for the receiver and not for the balance.
    function test_zeroReceiverRefusedBeforeBalanceCheck() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), MAX);
    }

    /// @dev Round trip: A sends x to B, B sends x back; both balances are exactly restored.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Additivity: two transfers of a and b leave the same state as one transfer of a + b.
    function testFuzz_splitTransferEqualsSingleTransfer(uint256 a, uint256 b) public {
        a = bound(a, 0, EXPECTED_SUPPLY);
        b = bound(b, 0, EXPECTED_SUPPLY - a);

        uint256 snapshot = vm.snapshotState();
        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.transfer(alice, b);
        vm.stopPrank();
        uint256 aliceSplit = token.balanceOf(alice);
        uint256 deployerSplit = token.balanceOf(deployer);

        vm.revertToState(snapshot);
        vm.prank(deployer);
        token.transfer(alice, a + b);

        assertEq(token.balanceOf(alice), aliceSplit);
        assertEq(token.balanceOf(deployer), deployerSplit);
        assertEq(token.balanceOf(alice), a + b);
    }

    /// @dev Conservation over a chain of hops through three holders.
    function testFuzz_multiHopConservesSupply(uint256 x, uint256 y, uint256 z) public {
        x = bound(x, 0, EXPECTED_SUPPLY);
        y = bound(y, 0, x);
        z = bound(z, 0, y);
        vm.prank(deployer);
        token.transfer(alice, x);
        vm.prank(alice);
        token.transfer(bob, y);
        vm.prank(bob);
        token.transfer(carol, z);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - x);
        assertEq(token.balanceOf(alice), x - y);
        assertEq(token.balanceOf(bob), y - z);
        assertEq(token.balanceOf(carol), z);
        assertEq(
            token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol),
            EXPECTED_SUPPLY
        );
    }

    /// @dev The revert carries the exact balance and the exact request for any shortfall.
    function testFuzz_insufficientBalanceErrorIsExact(uint256 held, uint256 excess) public {
        held = bound(held, 0, EXPECTED_SUPPLY);
        excess = bound(excess, 1, MAX - held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + excess)
        );
        token.transfer(bob, held + excess);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev A transfer emits exactly one event, the Transfer, with the exact amount.
    function testFuzz_transferEmitsOnlyTransfer(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.recordLogs();
        vm.prank(deployer);
        token.transfer(alice, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(abi.decode(logs[0].data, (uint256)), amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances at the edges
    // ---------------------------------------------------------------------------------------------

    /// @dev approve overwrites; it never accumulates. Same call twice is idempotent.
    function testFuzz_approveOverwritesAndIsIdempotent(uint256 first, uint256 second) public {
        vm.startPrank(deployer);
        token.approve(alice, first);
        assertEq(token.allowance(deployer, alice), first);
        token.approve(alice, second);
        assertEq(token.allowance(deployer, alice), second);
        token.approve(alice, second);
        assertEq(token.allowance(deployer, alice), second);
        vm.stopPrank();
        // Other spenders and other owners are untouched.
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.allowance(alice, deployer), 0);
    }

    /// @dev Approving the same value twice emits Approval both times (no silent no-op).
    function test_repeatedApproveEmitsEachTime() public {
        vm.startPrank(deployer);
        for (uint256 i = 0; i < 2; i++) {
            vm.expectEmit(true, true, false, true);
            emit IERC20.Approval(deployer, alice, 77);
            token.approve(alice, 77);
        }
        vm.stopPrank();
    }

    function test_approveMaxThenZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(alice, MAX);
        assertEq(token.allowance(deployer, alice), MAX);
        token.approve(alice, 0);
        assertEq(token.allowance(deployer, alice), 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev Approving with no balance is allowed; the allowance is a promise, not a reservation.
    function test_approveWithoutBalanceIsAllowedButUnspendable() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, 1e18));
        assertEq(token.allowance(alice, bob), 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    /// @dev Only the exact maximum is treated as infinite: max - 1 is spent down like any value.
    function test_allowanceMaxMinusOneDecrements() public {
        vm.prank(deployer);
        token.approve(alice, MAX - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), MAX - 1 - 1e18);
    }

    /// @dev Spending exactly the allowance leaves zero and a further wei is refused.
    function testFuzz_spendingExactAllowanceLeavesZero(uint256 allowed) public {
        allowed = bound(allowed, 1, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        token.transferFrom(deployer, bob, allowed);
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.balanceOf(bob), allowed);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev Allowance accounting for any (allowance, amount) pair the call can succeed with.
    function testFuzz_transferFromDecrementsExactly(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, MAX);
        uint256 cap = allowed < EXPECTED_SUPPLY ? allowed : EXPECTED_SUPPLY;
        amount = bound(amount, 0, cap);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));
        uint256 expectedRemaining = allowed == MAX ? MAX : allowed - amount;
        assertEq(token.allowance(deployer, alice), expectedRemaining);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
    }

    /// @dev The allowance revert carries the exact allowance and the exact request.
    function testFuzz_insufficientAllowanceErrorIsExact(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, MAX - 1);
        excess = bound(excess, 1, MAX - allowed);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, allowed + excess)
        );
        token.transferFrom(deployer, bob, allowed + excess);
        assertEq(token.allowance(deployer, alice), allowed);
    }

    /// @dev Spending an allowance emits only Transfer; OpenZeppelin 5 does not re-emit Approval.
    function test_transferFromEmitsOnlyTransfer() public {
        vm.prank(deployer);
        token.approve(alice, 10e18);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(deployer))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 4e18);
    }

    /// @dev An owner can approve itself and pull its own funds through transferFrom.
    function test_ownerCanTransferFromItselfWithSelfAllowance() public {
        vm.startPrank(deployer);
        token.approve(deployer, 5e18);
        assertTrue(token.transferFrom(deployer, alice, 5e18));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    /// @dev Without a self-allowance, transferFrom on one's own funds is refused like anyone else's.
    function test_ownerCannotTransferFromItselfWithoutAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    /// @dev Standard ERC-20 behaviour worth pinning: a zero-value transferFrom needs no allowance
    ///      and emits a Transfer(from, to, 0). It moves nothing and changes no balance.
    function testFuzz_zeroTransferFromNeedsNoAllowance(address spender, address from) public {
        if (spender == address(0)) spender = alice;
        if (from == address(0)) from = deployer;
        vm.prank(spender);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(from, bob, 0);
        assertTrue(token.transferFrom(from, bob, 0));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(from), from == deployer ? EXPECTED_SUPPLY : 0);
    }

    /// @dev The zero address can never be a `from`: with no allowance the allowance check trips,
    ///      and with a zero amount, where the allowance comparison passes, writing the spent
    ///      allowance back for owner zero trips the approver check. Either way nothing moves.
    function test_transferFromZeroAddressSenderReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev The allowance check runs before the receiver check: with no allowance the error is the
    ///      allowance; with an allowance, the zero receiver is refused and the allowance is not spent.
    function test_transferFromToZeroAddressOrdering() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, address(0), 1);

        vm.prank(deployer);
        token.approve(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1);
        assertEq(token.allowance(deployer, alice), 1, "a reverted transferFrom spent the allowance");
    }

    // ---------------------------------------------------------------------------------------------
    // Surface outside ERC-20
    // ---------------------------------------------------------------------------------------------

    /// @dev Any selector the token does not implement reverts, from anyone, and changes nothing.
    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes memory payload, address caller) public {
        bytes4[9] memory known = [
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.totalSupply.selector,
            token.balanceOf.selector,
            token.transfer.selector,
            token.allowance.selector,
            token.approve.selector,
            token.transferFrom.selector
        ];
        bytes4[2] memory constants = [token.SUPPLY_WHOLE_UNITS.selector, token.TOTAL_SUPPLY.selector];
        for (uint256 i = 0; i < known.length; i++) {
            if (selector == known[i]) selector = bytes4(uint32(selector) ^ 0xdeadbeef);
        }
        for (uint256 i = 0; i < constants.length; i++) {
            if (selector == constants[i]) selector = bytes4(uint32(selector) ^ 0xdeadbeef);
        }
        for (uint256 i = 0; i < known.length; i++) {
            if (selector == known[i]) return; // the xor landed on a real selector; nothing to probe
        }
        for (uint256 i = 0; i < constants.length; i++) {
            if (selector == constants[i]) return;
        }

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, payload));
        assertFalse(ok, "an unimplemented selector was accepted");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    /// @dev No function is payable: any ether, with any calldata, is refused.
    function testFuzz_anyCallWithValueReverts(uint256 value, bytes memory payload, address caller) public {
        value = bound(value, 1, 1_000_000 ether);
        // The fuzzer draws addresses it has seen, including the token's own; funding the token
        // through `deal` would make the ether check meaningless, so redirect those two cases.
        if (caller == address(0) || caller == address(token)) caller = alice;
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(payload);
        assertFalse(ok, "a call carrying ether succeeded");
        assertEq(address(token).balance, 0);
        assertEq(caller.balance, value);
    }

    /// @dev A valid transfer carrying ether is refused too, and moves no tokens.
    function test_transferWithValueRevertsAndMovesNothing() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(token.transfer, (alice, 1e18)));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    /// @dev Short calldata (a selector with truncated arguments) is refused, not zero-padded.
    function test_truncatedCalldataReverts() public {
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(token.transfer.selector, alice));
        assertFalse(ok, "truncated transfer calldata was accepted");
        assertEq(token.balanceOf(alice), 0);
    }
}
