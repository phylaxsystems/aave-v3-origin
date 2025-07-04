// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';

contract WorkingProtocol is IMockL2Pool {
  mapping(address => mapping(address => uint256)) public userCollateral;
  mapping(address => mapping(address => uint256)) public userDebt;
  mapping(address => uint256) public healthFactors;
  mapping(address => uint40) public liquidationGracePeriods;
  mapping(address => uint256) public reserveDeficits;
  mapping(address => bool) public reserveActive;
  mapping(address => bool) public reserveFrozen;
  mapping(address => bool) public reservePaused;

  address public immutable admin;
  bool public paused;

  constructor() {
    admin = msg.sender;
  }

  function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
    userCollateral[onBehalfOf][asset] += amount;
    _updateHealthFactor(onBehalfOf);
  }

  function borrow(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    uint16 referralCode,
    address onBehalfOf
  ) external {
    userDebt[onBehalfOf][asset] += amount;
    _updateHealthFactor(onBehalfOf);
  }

  function repay(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    address onBehalfOf
  ) external returns (uint256) {
    userDebt[onBehalfOf][asset] -= amount;
    _updateHealthFactor(onBehalfOf);
    return amount;
  }

  function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
    userCollateral[msg.sender][asset] -= amount;
    _updateHealthFactor(msg.sender);
    return amount;
  }

  function liquidationCall(
    address collateralAsset,
    address debtAsset,
    address user,
    uint256 debtToCover,
    bool receiveAToken
  ) external {
    require(!paused, 'Protocol paused');
    require(healthFactors[user] < 1e18, 'User health factor not below 1');

    uint40 gracePeriod = liquidationGracePeriods[collateralAsset];
    if (gracePeriod > 0) {
      require(block.timestamp > gracePeriod, 'In grace period');
    }

    // Simple liquidation logic - just clear the debt and collateral
    uint256 collateralToLiquidate = userCollateral[user][collateralAsset];
    uint256 debtToLiquidate = userDebt[user][debtAsset];

    userCollateral[user][collateralAsset] = 0;
    userDebt[user][debtAsset] = 0;

    // Transfer collateral to liquidator
    if (receiveAToken) {
      // Mock aToken transfer
    } else {
      // Mock underlying transfer
    }

    _updateHealthFactor(user);
  }

  function getUserAccountData(
    address user
  )
    external
    view
    override
    returns (
      uint256 totalCollateralBase,
      uint256 totalDebtBase,
      uint256 availableBorrowsBase,
      uint256 currentLiquidationThreshold,
      uint256 ltv,
      uint256 healthFactor
    )
  {
    healthFactor = healthFactors[user];
    return (0, 0, 0, 0, 0, healthFactor);
  }

  function getReserveData(
    address asset
  ) external view returns (DataTypes.ReserveDataLegacy memory) {
    DataTypes.ReserveDataLegacy memory data;
    // Set the configuration based on reserve state
    data.configuration.data = 0;
    if (reserveActive[asset]) {
      data.configuration.data |= 1 << 56; // ACTIVE_MASK position
    }
    if (reserveFrozen[asset]) {
      data.configuration.data |= 1 << 57; // FROZEN_MASK position
    }
    if (reservePaused[asset]) {
      data.configuration.data |= 1 << 60; // PAUSED_MASK position
    }
    return data;
  }

  function getUserConfiguration(
    address user
  ) external pure returns (DataTypes.UserConfigurationMap memory) {
    return DataTypes.UserConfigurationMap(0);
  }

  function getCloseFactor() external pure returns (uint256) {
    return 0.5e18; // 50%
  }

  function MIN_BASE_MAX_CLOSE_FACTOR_THRESHOLD() external pure returns (uint256) {
    return 0.5e18; // 50%
  }

  function MIN_LEFTOVER_BASE() external pure returns (uint256) {
    return 0.1e18; // 10%
  }

  function getUserCollateralBalance(address user, address asset) external view returns (uint256) {
    return userCollateral[user][asset];
  }

  function getUserDebtBalance(address user, address asset) external view returns (uint256) {
    return userDebt[user][asset];
  }

  function getLiquidationGracePeriod(address asset) external view returns (uint40) {
    return liquidationGracePeriods[asset];
  }

  function getReserveDeficit(address asset) external view returns (uint256) {
    return reserveDeficits[asset];
  }

  function getVirtualUnderlyingBalance(address asset) external view returns (uint128) {
    // Return a reasonable virtual balance for the working protocol
    return 1000e6; // 1000 tokens as default virtual balance
  }

  function getReserveAddressById(uint16) external pure returns (address) {
    return address(0);
  }

  function setReserveActive(address asset, bool active) external {
    require(msg.sender == admin, 'Only admin');
    reserveActive[asset] = active;
  }

  function setReserveFrozen(address asset, bool frozen) external {
    require(msg.sender == admin, 'Only admin');
    reserveFrozen[asset] = frozen;
  }

  function setReservePaused(address asset, bool isPaused) external {
    require(msg.sender == admin, 'Only admin');
    reservePaused[asset] = isPaused;
  }

  function setHealthFactor(address user, uint256 healthFactor) external {
    require(msg.sender == admin, 'Only admin');
    healthFactors[user] = healthFactor;
  }

  function setLiquidationGracePeriod(address asset, uint40 gracePeriod) external {
    require(msg.sender == admin, 'Only admin');
    liquidationGracePeriods[asset] = gracePeriod;
  }

  function setReserveDeficit(address asset, uint256 deficit) external {
    require(msg.sender == admin, 'Only admin');
    reserveDeficits[asset] = deficit;
  }

  function setPaused(bool _paused) external {
    require(msg.sender == admin, 'Only admin');
    paused = _paused;
  }

  function _updateHealthFactor(address user) internal {
    // Mock health factor update
    healthFactors[user] = 1.5e18; // Default to healthy
  }

  // Flashloan implementation
  function flashLoan(
    address receiverAddress,
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata modes,
    address onBehalfOf,
    bytes calldata params,
    uint16 referralCode
  ) external {}

  // Simple flashloan implementation
  function flashLoanSimple(
    address receiverAddress,
    address asset,
    uint256 amount,
    bytes calldata params,
    uint16 referralCode
  ) external {}

  // L2Pool function implementations
  function supply(bytes32 args) external {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard supply function
    this.supply(address(0), amount, msg.sender, 0);
  }

  function supplyWithPermit(bytes32 args, bytes32, bytes32) external {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard supply function
    this.supply(address(0), amount, msg.sender, 0);
  }

  function withdraw(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard withdraw function
    return this.withdraw(address(0), amount, msg.sender);
  }

  function borrow(bytes32 args) external {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard borrow function
    this.borrow(address(0), amount, 2, 0, msg.sender);
  }

  function repay(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard repay function
    return this.repay(address(0), amount, 2, msg.sender);
  }

  function repayWithPermit(bytes32 args, bytes32, bytes32) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard repay function
    return this.repay(address(0), amount, 2, msg.sender);
  }

  function repayWithATokens(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard repay function
    return this.repay(address(0), amount, 2, msg.sender);
  }

  function setUserUseReserveAsCollateral(bytes32 args) external {
    // No-op for testing
  }

  function liquidationCall(bytes32 args1, bytes32 args2) external {
    // Decode parameters (simplified)
    uint256 args1Uint = uint256(args1);
    uint256 args2Uint = uint256(args2);
    address user = address(uint160(args1Uint >> 32));
    uint256 debtToCover = args2Uint & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard liquidation function
    this.liquidationCall(address(0), address(0), user, debtToCover, false);
  }
}
