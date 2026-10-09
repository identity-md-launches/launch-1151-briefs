// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {BriefsToken} from "../src/BriefsToken.sol";

/// @title Deploy script for BriefsToken
/// @notice Reviewable deployment helper. The IdentityMD launch deploys the token itself from the
///         built bytecode, so this script is for local or independent deployments only.
/// @dev The token has no constructor arguments, so there is nothing to configure. `deploy()` is the
///      function tests call directly; `run()` only wraps it in a broadcast.
contract DeployBriefsToken is Script {
    /// @notice Deploys a new BriefsToken. The caller (the broadcasting account under `run()`)
    ///         receives the whole supply.
    function deploy() public returns (BriefsToken token) {
        token = new BriefsToken();
    }

    /// @notice Broadcasts the deployment with the sender configured on the command line.
    function run() external returns (BriefsToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
