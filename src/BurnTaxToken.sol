// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply, standard ERC-20. Swap taxation lives exclusively in the hook.
contract BurnTaxToken is ERC20 {
    constructor() ERC20("BurnTax", "BTAX") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
