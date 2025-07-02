// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '../../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

/// @title LiquidationInvariantAssertions
/// @notice Implements the liquidation invariants defined in LiquidationPostconditionsSpec.t.sol
/// @dev Each assertion function implements one or more invariants from LiquidationPostconditionsSpec
contract LiquidationInvariantAssertions is Assertion {
  function triggers() public view override {
    // Register triggers for liquidation functions
    registerCallTrigger(
      this.assertHealthFactorThreshold.selector,
      IMockL2Pool.liquidationCall.selector
    );
    registerCallTrigger(this.assertGracePeriod.selector, IMockL2Pool.liquidationCall.selector);
    registerCallTrigger(
      this.assertLiquidationAmounts.selector,
      IMockL2Pool.liquidationCall.selector
    );
    registerCallTrigger(this.assertDeficitCreation.selector, IMockL2Pool.liquidationCall.selector);
    registerCallTrigger(
      this.assertDeficitAccounting.selector,
      IMockL2Pool.liquidationCall.selector
    );
    registerCallTrigger(this.assertDeficitAmount.selector, IMockL2Pool.liquidationCall.selector);
    registerCallTrigger(
      this.assertActiveReserveDeficit.selector,
      IMockL2Pool.liquidationCall.selector
    );
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    CORE INVARIANT IMPLEMENTATIONS                               //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  // LIQUIDATION_HSPOST_A: A liquidation can only be performed once a users health-factor drops below 1
  function assertHealthFactorThreshold() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      bytes4(keccak256('liquidationCall(bytes32,bytes32)'))
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      address user = address(uint160(uint256(args1) >> 32));

      // Get health factor before liquidation
      ph.forkPreState();
      (, , , , , uint256 healthFactor) = pool.getUserAccountData(user);

      // Check health factor is below 1
      require(healthFactor < 1e18, 'User health factor not below 1');
    }
  }

  // LIQUIDATION_HSPOST_B: No position on a reserve can be liquidated under grace period
  function assertGracePeriod() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      bytes4(keccak256('liquidationCall(bytes32,bytes32)'))
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 collateralAssetId = uint16(uint256(args1));

      // Get the asset address from the assetId using the pool's function
      address collateralAsset = pool.getReserveAddressById(collateralAssetId);

      // Get grace period for the collateral asset
      uint40 gracePeriod = pool.getLiquidationGracePeriod(collateralAsset);

      // Check if we're in grace period
      require(block.timestamp >= gracePeriod, 'Liquidation during grace period');
    }
  }

  // LIQUIDATION_HSPOST_H: Liquidation must fully liquidate debt or fully liquidate collateral or leave at least MIN_LEFTOVER_BASE on both
  function assertLiquidationAmounts() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      bytes4(keccak256('liquidationCall(bytes32,bytes32)'))
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, bytes32 args2) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 collateralAssetId = uint16(uint256(args1));
      uint16 debtAssetId = uint16(uint256(args1) >> 16);
      address user = address(uint160(uint256(args1) >> 32));

      // Get the asset addresses from the assetIds
      address collateralAsset = pool.getReserveAddressById(collateralAssetId);
      address debtAsset = pool.getReserveAddressById(debtAssetId);

      // Get user data before liquidation
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(user);
      uint256 userDebt = pool.getUserDebtBalance(user, debtAsset);

      // Get user data after liquidation
      ph.forkPostState();
      (, uint256 postTotalDebtBase, , , , ) = pool.getUserAccountData(user);
      uint256 postUserDebt = pool.getUserDebtBalance(user, debtAsset);

      // Check if liquidation leaves sufficient amounts
      uint256 minLeftover = pool.MIN_LEFTOVER_BASE();

      // If debt is not fully liquidated, remaining debt should be >= min leftover
      if (postUserDebt > 0) {
        require(postUserDebt >= minLeftover, 'Insufficient debt leftover');
      }
    }
  }

  // LIQUIDATION_HSPOST_L: Liquidation only creates deficit if user collateral across reserves == 0 while debt across reserves != 0
  function assertDeficitCreation() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      bytes4(keccak256('liquidationCall(bytes32,bytes32)'))
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      address user = address(uint160(uint256(args1) >> 32));

      // Get user data after liquidation
      ph.forkPostState();
      (uint256 totalCollateralBase, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(user);

      // If deficit was created
      if (totalDebtBase > 0) {
        require(totalCollateralBase == 0, 'Deficit created with remaining collateral');
      }
    }
  }

  // LIQUIDATION_HSPOST_M: Whenever a deficit is created as a result of a liquidation, the user's excess debt should be burned and accounted for as deficit
  function assertDeficitAccounting() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      bytes4(keccak256('liquidationCall(bytes32,bytes32)'))
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 debtAssetId = uint16(uint256(args1) >> 16);
      address user = address(uint160(uint256(args1) >> 32));

      // Get the asset address from the assetId
      address debtAsset = pool.getReserveAddressById(debtAssetId);

      // Get user debt before liquidation
      ph.forkPreState();
      uint256 preUserDebt = pool.getUserDebtBalance(user, debtAsset);
      uint256 preReserveDeficit = pool.getReserveDeficit(debtAsset);

      // Get user debt after liquidation
      ph.forkPostState();
      uint256 postUserDebt = pool.getUserDebtBalance(user, debtAsset);
      uint256 postReserveDeficit = pool.getReserveDeficit(debtAsset);

      // If deficit was created (user debt burned but not fully liquidated)
      if (postUserDebt < preUserDebt && postUserDebt > 0) {
        uint256 debtBurned = preUserDebt - postUserDebt;
        uint256 deficitIncrease = postReserveDeficit - preReserveDeficit;
        require(deficitIncrease == debtBurned, 'Deficit accounting mismatch');
      }
    }
  }

  // LIQUIDATION_HSPOST_N: The deficit amount should be equal to the user's debt balance after liquidation
  function assertDeficitAmount() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      bytes4(keccak256('liquidationCall(bytes32,bytes32)'))
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 debtAssetId = uint16(uint256(args1) >> 16);
      address user = address(uint160(uint256(args1) >> 32));

      // Get the asset address from the assetId
      address debtAsset = pool.getReserveAddressById(debtAssetId);

      // Get user debt after liquidation
      ph.forkPostState();
      uint256 postUserDebt = pool.getUserDebtBalance(user, debtAsset);
      uint256 postReserveDeficit = pool.getReserveDeficit(debtAsset);

      // If there's a deficit, it should equal the user's remaining debt
      if (postReserveDeficit > 0) {
        require(postReserveDeficit == postUserDebt, 'Deficit amount mismatch');
      }
    }
  }

  // LIQUIDATION_HSPOST_O: Deficit can only be created on active reserves
  function assertActiveReserveDeficit() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      bytes4(keccak256('liquidationCall(bytes32,bytes32)'))
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 debtAssetId = uint16(uint256(args1) >> 16);

      // Get the asset address from the assetId
      address debtAsset = pool.getReserveAddressById(debtAssetId);

      // Get reserve data to check if it's active
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(debtAsset);
      bool isActive = ReserveConfiguration.getActive(reserveData.configuration);

      // Get reserve deficit after liquidation
      ph.forkPostState();
      uint256 postReserveDeficit = pool.getReserveDeficit(debtAsset);

      // If deficit was created, reserve must be active
      if (postReserveDeficit > 0) {
        require(isActive, 'Deficit created on inactive reserve');
      }
    }
  }
}
