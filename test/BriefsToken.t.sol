// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BriefsToken} from "../src/BriefsToken.sol";
import {DeployBriefsToken} from "../script/DeployBriefsToken.s.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 so the test can check
///         that `msg.sender` of the constructor, not the test, receives the supply.
contract FactoryStub {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }
}

contract BriefsTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    BriefsToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new BriefsToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Briefs");
        assertEq(token.symbol(), "BRIEFS");
        assertEq(token.decimals(), 18);
    }

    function test_supplyConstantsMatchTheBrief() public view {
        assertEq(token.SUPPLY_WHOLE_UNITS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), token.SUPPLY_WHOLE_UNITS() * 10 ** token.decimals());
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        new BriefsToken();
    }

    /// @dev When a factory deploys the token through CREATE2, the factory (the constructor's
    ///      msg.sender) holds the whole supply, not the account that called the factory.
    function test_create2DeploymentMintsToTheFactory() public {
        FactoryStub factory = new FactoryStub();
        address predicted =
            vm.computeCreate2Address(bytes32(uint256(7)), keccak256(type(BriefsToken).creationCode), address(factory));
        address deployed = factory.deploy(type(BriefsToken).creationCode, bytes32(uint256(7)));
        assertEq(deployed, predicted);
        BriefsToken viaFactory = BriefsToken(deployed);
        assertEq(viaFactory.totalSupply(), EXPECTED_SUPPLY);
        assertEq(viaFactory.balanceOf(address(factory)), EXPECTED_SUPPLY);
        assertEq(viaFactory.balanceOf(address(this)), 0);
    }

    function test_deployScriptMintsToTheCaller() public {
        DeployBriefsToken script = new DeployBriefsToken();
        BriefsToken deployed = script.deploy();
        // `deploy()` is an ordinary call, so the script contract is the constructor's msg.sender.
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234e18;
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalanceLeavesZero() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(stranger);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        token.transfer(bob, 10e18 + 1);
    }

    function test_transferFromStrangerWithNothingReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer) + token.balanceOf(to), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(deployer, alice, 500e18);
        assertTrue(token.approve(alice, 500e18));
        assertEq(token.allowance(deployer, alice), 500e18);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 500e18);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 300e18));
        assertEq(token.balanceOf(bob), 300e18);
        assertEq(token.allowance(deployer, alice), 200e18);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferFromWithInfiniteAllowanceDoesNotDecrement() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 100e18, 100e18 + 1)
        );
        token.transferFrom(deployer, bob, 100e18 + 1);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1));
        token.transferFrom(deployer, stranger, 1);
    }

    function test_transferFromRevertsWhenOwnerBalanceIsShort() public {
        vm.prank(deployer);
        token.transfer(alice, 5e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5e18, 6e18));
        token.transferFrom(alice, bob, 6e18);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Fixed supply and absence of privileged powers
    // ---------------------------------------------------------------------------------------------

    /// @dev No common mint, ownership or upgrade entry point exists. Each call must leave the supply
    ///      and the attacker's balance unchanged whether a stranger or the deployer tries it.
    function test_noAdminCallCanIncreaseSupply() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    /// @dev No pause, blocklist, freeze or seize entry point exists; the deployer cannot move or
    ///      freeze a holder's balance, and the holder can still transfer afterwards.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 1_000e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 400e18));
        assertEq(token.balanceOf(bob), 400e18);
        assertEq(token.balanceOf(alice), 600e18);
    }

    function test_burnFunctionsDoNotExist() public {
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }
}
