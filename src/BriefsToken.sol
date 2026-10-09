// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Briefs (BRIEFS)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 BRIEFS (18 decimals) is minted
///         once, in the constructor, to the deployer (`msg.sender`). There is no owner, no minter,
///         no pause, no blocklist, no fee and no burn hook: after construction nothing can create,
///         move or freeze a balance except its holder through the standard ERC-20 functions.
/// @dev The Solidity identifier `BriefsToken` is the launch manifest's contract name; `name()` and
///      `symbol()` return the token's own name and symbol. The constructor takes no arguments and
///      makes no external calls, so it deploys on an empty chain. When deployed through the launch
///      factory, `msg.sender` is the factory, which then pays out the entire supply.
contract BriefsToken is ERC20 {
    /// @notice The token name returned by `name()`.
    string private constant NAME = "Briefs";

    /// @notice The token symbol returned by `symbol()`.
    string private constant SYMBOL = "BRIEFS";

    /// @notice Whole-unit supply, before scaling by `decimals()`.
    uint256 public constant SUPPLY_WHOLE_UNITS = 1_000_000_000;

    /// @notice The entire supply in minor units: 1,000,000,000 * 10^18. Minted once; never changes.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_UNITS * 10 ** 18;

    /// @notice Mints the whole fixed supply to the deployer.
    constructor() ERC20(NAME, SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
