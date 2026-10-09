// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BriefsToken} from "../../src/BriefsToken.sol";

/// @notice Drives `BriefsToken` with bounded inputs from a small set of actors and keeps a ghost
///         ledger of what every balance and allowance must be. Every call that is expected to fail
///         is asserted to fail with the exact ERC-6093 error and to leave state untouched, so the
///         failure paths are exercised inside random sequences, not only in unit tests.
/// @dev The ghost ledger is built from the amounts each call asked to move. If the token ever moved
///      more or less than that (a fee, a reflection, a rounding step, a hidden mint or burn), the
///      invariants over the ledger fail and the sequence is the finding.
contract BriefsTokenHandler is Test {
    BriefsToken public immutable token;

    /// @dev Every address that can ever hold a balance. The deployer is `actors[0]`.
    address[] public actors;

    /// @dev What each actor must hold: initial grant plus everything received minus everything sent.
    mapping(address => uint256) public ghostBalance;
    /// @dev What each (owner, spender) allowance must read.
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    /// @dev Cumulative value moved by successful transfers and transferFroms.
    uint256 public ghostMoved;
    /// @dev Counters used to show the suite actually exercised each path.
    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public approvals;
    uint256 public revertsObserved;
    uint256 public rejectedForeignCalls;
    uint256 public rejectedEtherDeposits;

    constructor(BriefsToken token_, address[] memory actors_) {
        token = token_;
        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Happy paths, bounded so they must succeed
    // ---------------------------------------------------------------------------------------------

    /// @notice A holder sends between zero and its whole balance to another actor (possibly itself).
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
        successfulTransfers++;
    }

    /// @notice An owner sets any allowance, including zero and the infinite sentinel, for a spender.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Bias the fuzzer toward the two values with special meaning in `_spendAllowance`.
        if (amount % 7 == 0) amount = type(uint256).max;
        else if (amount % 7 == 1) amount = 0;

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");

        ghostAllowance[owner][spender] = amount;
        approvals++;
    }

    /// @notice A spender moves between zero and min(balance, allowance) from an owner to any actor.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < balance ? allowed : balance);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
        if (allowed != type(uint256).max) {
            ghostAllowance[owner][spender] = allowed - amount;
        }
        successfulTransferFroms++;
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths, asserted inside the sequence
    // ---------------------------------------------------------------------------------------------

    /// @notice A holder tries to send more than it has. Must revert with the exact balance error.
    function transferExceedingBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        token.transfer(to, amount);

        assertEq(token.balanceOf(from), balance, "a failed transfer changed the sender's balance");
        revertsObserved++;
    }

    /// @notice Nobody can send to the zero address, not even nothing.
    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        revertsObserved++;
    }

    /// @notice A spender tries to move more than the owner allowed. Must revert with the exact
    ///         allowance error. Skipped when the allowance is infinite, since then nothing is "more".
    function transferFromExceedingAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return;
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);

        assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom changed the allowance");
        revertsObserved++;
    }

    /// @notice An approved spender tries to move more than the owner holds. The owner first grants
    ///         an infinite allowance so the balance check, not the allowance check, is what trips.
    function transferFromExceedingBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);

        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghostAllowance[owner][spender] = type(uint256).max;
        approvals++;

        uint256 balance = token.balanceOf(owner);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        token.transferFrom(owner, to, amount);

        assertEq(token.balanceOf(owner), balance, "a failed transferFrom changed the owner's balance");
        revertsObserved++;
    }

    /// @notice Any actor, including the deployer, calls a selector the token does not implement:
    ///         mint, burn, pause, owner-style admin calls, or a random four bytes. Every one must
    ///         revert, so nothing outside the ERC-20 surface can change state.
    function callForeignSelector(uint256 callerSeed, uint256 which, bytes32 arg) external {
        address caller = _actor(callerSeed);
        bytes4 selector = _foreignSelector(which);
        bytes memory data = abi.encodePacked(selector, arg, uint256(type(uint128).max));

        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a selector outside ERC-20 was accepted");
        rejectedForeignCalls++;
    }

    /// @notice Ether sent to the token, with or without calldata, must bounce.
    function sendEther(uint256 fromSeed, uint256 value, bool withCalldata) external {
        address from = _actor(fromSeed);
        value = bound(value, 1, 1_000 ether);
        vm.deal(from, value);
        bytes memory data = withCalldata ? abi.encodeCall(token.totalSupply, ()) : bytes("");

        vm.prank(from);
        (bool ok,) = address(token).call{value: value}(data);
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
        rejectedEtherDeposits++;
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Selectors a privileged or upgradeable token would expose. None exist here. The last
    ///      branch feeds a pseudo-random selector so the fallback-less surface is probed too.
    function _foreignSelector(uint256 which) internal pure returns (bytes4) {
        which = bound(which, 0, 15);
        if (which == 0) return bytes4(keccak256("mint(address,uint256)"));
        if (which == 1) return bytes4(keccak256("mint(uint256)"));
        if (which == 2) return bytes4(keccak256("burn(uint256)"));
        if (which == 3) return bytes4(keccak256("burnFrom(address,uint256)"));
        if (which == 4) return bytes4(keccak256("pause()"));
        if (which == 5) return bytes4(keccak256("unpause()"));
        if (which == 6) return bytes4(keccak256("blacklist(address)"));
        if (which == 7) return bytes4(keccak256("freeze(address)"));
        if (which == 8) return bytes4(keccak256("seize(address)"));
        if (which == 9) return bytes4(keccak256("transferOwnership(address)"));
        if (which == 10) return bytes4(keccak256("upgradeTo(address)"));
        if (which == 11) return bytes4(keccak256("initialize(address)"));
        if (which == 12) return bytes4(keccak256("setFee(uint256)"));
        if (which == 13) return bytes4(keccak256("increaseAllowance(address,uint256)"));
        if (which == 14) return bytes4(keccak256("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));
        return bytes4(keccak256(abi.encodePacked("foreign", which)));
    }
}
