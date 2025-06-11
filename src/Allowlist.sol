// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Allowlist is Ownable, AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    mapping(address => bool) private allowlist; // Made private to ensure access through getter

    event Allowlisted(address indexed account);
    event RemovedFromAllowlist(address indexed account); // New: Event for removal

    modifier isAdminOrOwner() {
        require(
            _msgSender() == owner() || hasRole(ADMIN_ROLE, _msgSender()), "Only admins and owner can call this function"
        );
        _;
    }

    constructor() Ownable(_msgSender()) {
        allowlist[_msgSender()] = true; // Automatically add deployer to the allowlist
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // Give deployer full admin control
        _grantRole(ADMIN_ROLE, _msgSender()); // Assign deployer as ADMIN_ROLE
    }

    function addToAllowlist(address _address) external isAdminOrOwner {
        allowlist[_address] = true;
        emit Allowlisted(_address);
    }

    function removeFromAllowlist(address _address) external isAdminOrOwner {
        allowlist[_address] = false;
        emit RemovedFromAllowlist(_address); // Fixed: Emitting event on removal
    }

    function isAllowlisted(address _address) public view returns (bool) {
        return allowlist[_address];
    }

    function hasAdminRole(address _address) external view returns (bool) {
        return hasRole(ADMIN_ROLE, _address);
    }

    function grantRole(bytes32 role, address account) public override {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Only default admin can grant roles");
        super.grantRole(role, account);
    }
}
