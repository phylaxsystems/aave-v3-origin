// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockPool} from './IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IAToken} from '../../src/contracts/interfaces/IAToken.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {ReserveConfiguration} from '../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../../src/contracts/protocol/libraries/configuration/UserConfiguration.sol';

contract LendingPostConditionAssertions is Assertion {
  IMockPool public immutable pool;

  constructor(IMockPool _pool) {
    pool = _pool;
  }

  function triggers() public view override {
    // Register triggers for core lending functions
    registerCallTrigger(this.assertDepositConditions.selector, pool.supply.selector);
    registerCallTrigger(this.assertWithdrawConditions.selector, pool.withdraw.selector);
    registerCallTrigger(this.assertTotalSupplyCap.selector, pool.supply.selector);
    registerCallTrigger(
      this.assertDepositBalanceChangesWithoutHelper.selector,
      pool.supply.selector
    );
    //registerCallTrigger(this.assertDepositBalanceChanges.selector, pool.supply.selector);
    registerCallTrigger(this.assertWithdrawBalanceChanges.selector, pool.withdraw.selector);
    registerCallTrigger(this.assertCollateralWithdrawHealth.selector, pool.withdraw.selector);
  }

  // LENDING_HPOST_A: An asset can only be deposited when the related reserve is active, not frozen & not paused
  function assertDepositConditions() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, , , ) = abi.decode(callInputs[i].input, (address, uint256, address, uint16));

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check reserve is active, not frozen and not paused
      require(ReserveConfiguration.getActive(reserveData.configuration), 'Reserve is not active');
      require(!ReserveConfiguration.getFrozen(reserveData.configuration), 'Reserve is frozen');
      require(!ReserveConfiguration.getPaused(reserveData.configuration), 'Reserve is paused');
    }
  }

  // LENDING_HPOST_B: An asset can only be withdrawn when the related reserve is active & not paused
  function assertWithdrawConditions() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, , ) = abi.decode(callInputs[i].input, (address, uint256, address));

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check reserve is active and not paused
      require(ReserveConfiguration.getActive(reserveData.configuration), 'Reserve is not active');
      require(!ReserveConfiguration.getPaused(reserveData.configuration), 'Reserve is paused');
    }
  }

  // LENDING_GPOST_C: If totalSupply for a reserve increases new totalSupply must be less than or equal to supply cap
  function assertTotalSupplyCap() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, , , ) = abi.decode(callInputs[i].input, (address, uint256, address, uint16));

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Get aToken
      IAToken aToken = IAToken(reserveData.aTokenAddress);

      // Get total supply before and after
      ph.forkPreState();
      uint256 preTotalSupply = aToken.totalSupply();

      ph.forkPostState();
      uint256 postTotalSupply = aToken.totalSupply();

      // If supply increased, check against cap
      require(postTotalSupply > preTotalSupply, 'Total supply did not increase');
      uint256 supplyCap = ReserveConfiguration.getSupplyCap(reserveData.configuration);
      if (supplyCap != 0) {
        // 0 means no cap
        require(postTotalSupply <= supplyCap, 'Total supply exceeds supply cap');
      }
    }
  }

  // // LENDING_HPOST_D: After a successful deposit the sender underlying balance should decrease by the amount deposited
  // // LENDING_HPOST_E: After a successful deposit the onBehalf AToken balance should increase by the amount deposited
  // function assertDepositBalanceChanges() external {
  //   PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
  //   // Should never happen, due to the trigger being registered for the function
  //   if (callInputs.length == 0) {
  //     return;
  //   } else if (callInputs.length == 1) {
  //     // Be specific for 1 input to save gas
  //     (address asset, uint256 amount, address onBehalfOf, ) = abi.decode(
  //       callInputs[0].input,
  //       (address, uint256, address, uint16)
  //     );
  //     address caller = callInputs[0].caller;
  //     _checkDepositBalanceChange(asset, caller, onBehalfOf, amount);
  //   } else {
  //     // Accumulate all deposit amounts and compare to deltas of sender balance and aToken balance
  //     uint256 totalDepositAmount = 0;
  //     address asset;
  //     uint256 amount;
  //     address onBehalfOf;
  //     address caller;
  //     for (uint256 i = 0; i < callInputs.length; i++) {
  //       (asset, amount, onBehalfOf, ) = abi.decode(
  //         callInputs[i].input,
  //         (address, uint256, address, uint16)
  //       );
  //       caller = callInputs[i].caller;
  //       totalDepositAmount += amount;
  //       // Note in a realistic scenario we would also need to loop through all the potential assets
  //       // that could be in a batch. For simplicity we omit this for now and only use one asset.
  //     }
  //     _checkDepositBalanceChange(asset, caller, onBehalfOf, totalDepositAmount);
  //   }
  // }

  // function _checkDepositBalanceChange(
  //   address asset,
  //   address caller,
  //   address onBehalfOf,
  //   uint256 amount
  // ) internal {
  //   // Get reserve data
  //   DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

  //   // Get aToken
  //   IERC20 aToken = IERC20(reserveData.aTokenAddress);

  //   // Get underlying token
  //   IERC20 underlying = IERC20(asset);

  //   // Get balances before
  //   ph.forkPreState();
  //   uint256 preSenderBalance = underlying.balanceOf(caller);
  //   uint256 preATokenBalance = aToken.balanceOf(onBehalfOf);

  //   // Get balances after
  //   ph.forkPostState();
  //   uint256 postSenderBalance = underlying.balanceOf(caller);
  //   uint256 postATokenBalance = aToken.balanceOf(onBehalfOf);

  //   // Check sender balance decreased by amount
  //   require(
  //     preSenderBalance - postSenderBalance == amount,
  //     'Sender balance did not decrease by deposit amount'
  //   );

  //   // Check aToken balance increased by amount
  //   require(
  //     postATokenBalance - preATokenBalance == amount,
  //     'AToken balance did not increase by deposit amount'
  //   );
  // }

  function assertDepositBalanceChangesWithoutHelper() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    // Should never happen, due to the trigger being registered for the function
    if (callInputs.length == 0) {
      return;
    } else if (callInputs.length == 1) {
      // Be specific for 1 input to save gas
      (address asset, uint256 amount, address onBehalfOf, ) = abi.decode(
        callInputs[0].input,
        (address, uint256, address, uint16)
      );
      address caller = callInputs[0].caller;
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Get aToken
      IERC20 aToken = IERC20(reserveData.aTokenAddress);

      // Get underlying token
      IERC20 underlying = IERC20(asset);

      // Get balances before
      ph.forkPreState();
      uint256 preSenderBalance = underlying.balanceOf(caller);
      uint256 preATokenBalance = aToken.balanceOf(onBehalfOf);

      // Get balances after
      ph.forkPostState();
      uint256 postSenderBalance = underlying.balanceOf(caller);
      uint256 postATokenBalance = aToken.balanceOf(onBehalfOf);

      // Check sender balance decreased by amount
      require(
        preSenderBalance - postSenderBalance == amount,
        'Sender balance did not decrease by deposit amount'
      );

      // Check aToken balance increased by amount
      require(
        postATokenBalance - preATokenBalance == amount,
        'AToken balance did not increase by deposit amount'
      );
    } else {
      // Accumulate all deposit amounts and compare to deltas of sender balance and aToken balance
      uint256 totalDepositAmount = 0;
      address asset;
      uint256 amount;
      address onBehalfOf;
      address caller;
      for (uint256 i = 0; i < callInputs.length; i++) {
        (asset, amount, onBehalfOf, ) = abi.decode(
          callInputs[i].input,
          (address, uint256, address, uint16)
        );
        caller = callInputs[i].caller;
        totalDepositAmount += amount;
        // Note in a realistic scenario we would also need to loop through all the potential assets
        // that could be in a batch. For simplicity we omit this for now and only use one asset.
      }
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Get aToken
      IERC20 aToken = IERC20(reserveData.aTokenAddress);

      // Get underlying token
      IERC20 underlying = IERC20(asset);

      // Get balances before
      ph.forkPreState();
      uint256 preSenderBalance = underlying.balanceOf(caller);
      uint256 preATokenBalance = aToken.balanceOf(onBehalfOf);

      // Get balances after
      ph.forkPostState();
      uint256 postSenderBalance = underlying.balanceOf(caller);
      uint256 postATokenBalance = aToken.balanceOf(onBehalfOf);

      // Check sender balance decreased by amount
      require(
        preSenderBalance - postSenderBalance == amount,
        'Sender balance did not decrease by deposit amount'
      );

      // Check aToken balance increased by amount
      require(
        postATokenBalance - preATokenBalance == amount,
        'AToken balance did not increase by deposit amount'
      );
    }
  }

  // LENDING_HPOST_F: After a successful withdraw the actor AToken balance should decrease by the amount withdrawn
  // LENDING_HPOST_G: After a successful withdraw the `to` underlying balance should increase by the amount withdrawn
  function assertWithdrawBalanceChanges() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, uint256 amount, address to) = abi.decode(
        callInputs[i].input,
        (address, uint256, address)
      );

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Get aToken
      IAToken aToken = IAToken(reserveData.aTokenAddress);

      // Get underlying token
      IERC20 underlying = IERC20(asset);

      // Get balances before
      ph.forkPreState();
      uint256 preATokenBalance = aToken.balanceOf(callInputs[i].caller);
      uint256 preToBalance = underlying.balanceOf(to);

      // Get balances after
      ph.forkPostState();
      uint256 postATokenBalance = aToken.balanceOf(callInputs[i].caller);
      uint256 postToBalance = underlying.balanceOf(to);

      // Check aToken balance decreased by amount
      require(
        preATokenBalance - postATokenBalance == amount,
        'AToken balance did not decrease by withdraw amount'
      );

      // Check underlying balance increased by amount
      require(
        postToBalance - preToBalance == amount,
        'Underlying balance did not increase by withdraw amount'
      );
    }
  }

  // LENDING_HPOST_H1: Before a successful withdraw of collateral, caller should be healthy
  // LENDING_HPOST_H2: After a successful withdraw of collateral, caller should remain healthy
  function assertCollateralWithdrawHealth() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, , ) = abi.decode(callInputs[i].input, (address, uint256, address));

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check if asset is being used as collateral
      DataTypes.UserConfigurationMap memory userConfig = pool.getUserConfiguration(
        callInputs[i].caller
      );
      bool isCollateral = UserConfiguration.isUsingAsCollateral(userConfig, reserveData.id);

      if (isCollateral) {
        // Get health factor before
        ph.forkPreState();
        (, , , , , uint256 preHealthFactor) = pool.getUserAccountData(callInputs[i].caller);

        // Check health before withdraw
        require(preHealthFactor >= 1e18, 'User not healthy before collateral withdraw');

        // Get health factor after
        ph.forkPostState();
        (, , , , , uint256 postHealthFactor) = pool.getUserAccountData(callInputs[i].caller);

        // Check health after withdraw
        require(postHealthFactor >= 1e18, 'User not healthy after collateral withdraw');
      }
    }
  }
}
