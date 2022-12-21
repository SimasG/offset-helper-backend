// SPDX-FileCopyrightText: 2022 Toucan Labs
//
// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "hardhat/console.sol";
// ** Why are we using the upgradeable version?
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// ** Why are we creating `OffsetHelperStorage` instead of just keeping it in `OffsetHelper`?
contract OffsetHelperStorage is OwnableUpgradeable {
    // token symbol => token address
    // ** `string` vs `bytes32`. `string` is unlimited. Why use it here then?
    mapping(string => address) public eligibleTokenAddresses;

    // ** What does contract registry do exactly? Is it basically a list of all eligible token addresses
    // ** we can offset (i.e. BCT/NCT/TCO2)?
    address public contractRegistryAddress =
        0x263fA1c180889b3a3f46330F32a4a23287E99FC9;

    // ** What does `sushiRouterAddress` do? Token swaps?
    address public sushiRouterAddress =
        0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;

    // user => (token => amount)
    mapping(address => mapping(address => uint256)) public balances;
}
