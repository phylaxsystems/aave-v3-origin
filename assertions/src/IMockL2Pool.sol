// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IPriceOracleGetter} from '../../src/contracts/interfaces/IPriceOracleGetter.sol';

interface IMockL2Pool {
  // L2Pool functions with compact parameters
  function supply(bytes32 args) external;
  function supplyWithPermit(bytes32 args, bytes32 r, bytes32 s) external;
  function withdraw(bytes32 args) external returns (uint256);
  function borrow(bytes32 args) external;
  function repay(bytes32 args) external returns (uint256);
  function repayWithPermit(bytes32 args, bytes32 r, bytes32 s) external returns (uint256);
  function repayWithATokens(bytes32 args) external returns (uint256);
  function setUserUseReserveAsCollateral(bytes32 args) external;
  function liquidationCall(bytes32 args1, bytes32 args2) external;

  // Standard getter functions (inherited from Pool)
  function getUserAccountData(
    address user
  )
    external
    view
    returns (
      uint256 totalCollateralBase,
      uint256 totalDebtBase,
      uint256 availableBorrowsBase,
      uint256 currentLiquidationThreshold,
      uint256 ltv,
      uint256 healthFactor
    );

  function getReserveData(address asset) external view returns (DataTypes.ReserveDataLegacy memory);

  function getReserveAddressById(uint16 id) external view returns (address);

  function getUserConfiguration(
    address user
  ) external view returns (DataTypes.UserConfigurationMap memory);

  // Liquidation-related functions
  function getLiquidationGracePeriod(address asset) external view returns (uint40);
  function getCloseFactor() external pure returns (uint256);
  function MIN_BASE_MAX_CLOSE_FACTOR_THRESHOLD() external pure returns (uint256);
  function MIN_LEFTOVER_BASE() external pure returns (uint256);
  function getUserCollateralBalance(address user, address asset) external view returns (uint256);
  function getUserDebtBalance(address user, address asset) external view returns (uint256);
  function getReserveDeficit(address asset) external view returns (uint256);

  // Flashloan functions (inherited from Pool)
  function flashLoan(
    address receiverAddress,
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata modes,
    address onBehalfOf,
    bytes calldata params,
    uint16 referralCode
  ) external;

  function flashLoanSimple(
    address receiverAddress,
    address asset,
    uint256 amount,
    bytes calldata params,
    uint16 referralCode
  ) external;
}
