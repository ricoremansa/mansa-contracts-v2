pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USD token for testing
contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "MUSD") {
        _mint(msg.sender, 10000000 * 10 ** decimals()); // 10 million tokens instead of 1 million
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // Function to create tokens for testing
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
