// SPDX-FileCopyrightText: 2022 Toucan Labs
//
// SPDX-License-Identifier: GPL-3.0

// If you encounter a vulnerability or an issue, please contact <security@toucan.earth> or visit security.toucan.earth

pragma solidity >=0.8.4 <0.9.0;

/// @dev CarbonProject related data and attributes
struct ProjectData {
    string projectId;
    string standard;
    string methodology;
    string region;
    string storageMethod;
    string method;
    string emissionType;
    string category;
    string uri;
    address controller;
}
