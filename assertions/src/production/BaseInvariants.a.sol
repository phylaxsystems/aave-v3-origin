// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IScaledBalanceToken} from '../../../src/contracts/interfaces/IScaledBalanceToken.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '../../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {WadRayMath} from '../../../src/contracts/protocol/libraries/math/WadRayMath.sol';

/**
 * @title BaseInvariants
 * @notice Assertions for basic protocol invariants related to token balances and borrowing states for a specific asset
 */
contract BaseInvariants is Assertion {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  address public immutable targetAsset;
  IMockL2Pool public immutable pool;

  constructor(address _pool, address _asset) {
    pool = IMockL2Pool(_pool);
    targetAsset = _asset;
  }

  function triggers() public view override {
    // Below approach is inefficient since we have to trigger on all calls to functions that _could_
    // affect the debt token supply, but without being sure that it's the token
    // at the address of the debt token initiated in the constructor.
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.liquidationCall.selector);

    // Register triggers for aToken supply invariant
    registerCallTrigger(this.assertATokenSupply.selector, IMockL2Pool.supply.selector);
    registerCallTrigger(this.assertATokenSupply.selector, IMockL2Pool.withdraw.selector);
    registerCallTrigger(this.assertATokenSupply.selector, IMockL2Pool.liquidationCall.selector);

    // Register triggers for underlying balance invariants
    registerCallTrigger(
      this.assertUnderlyingBalanceInvariant.selector,
      IMockL2Pool.supply.selector
    );
    registerCallTrigger(
      this.assertUnderlyingBalanceInvariant.selector,
      IMockL2Pool.withdraw.selector
    );
    registerCallTrigger(
      this.assertUnderlyingBalanceInvariant.selector,
      IMockL2Pool.borrow.selector
    );
    registerCallTrigger(this.assertUnderlyingBalanceInvariant.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(
      this.assertUnderlyingBalanceInvariant.selector,
      IMockL2Pool.liquidationCall.selector
    );

    // Register triggers for virtual balance invariant
    registerCallTrigger(this.assertVirtualBalanceInvariant.selector, IMockL2Pool.supply.selector);
    registerCallTrigger(this.assertVirtualBalanceInvariant.selector, IMockL2Pool.withdraw.selector);
    registerCallTrigger(this.assertVirtualBalanceInvariant.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertVirtualBalanceInvariant.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(
      this.assertVirtualBalanceInvariant.selector,
      IMockL2Pool.liquidationCall.selector
    );

    // Register triggers for frozen reserve LTV invariant
    registerCallTrigger(this.assertFrozenReserveLtvInvariant.selector, IMockL2Pool.supply.selector);
    registerCallTrigger(
      this.assertFrozenReserveLtvInvariant.selector,
      IMockL2Pool.withdraw.selector
    );
    registerCallTrigger(this.assertFrozenReserveLtvInvariant.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertFrozenReserveLtvInvariant.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(
      this.assertFrozenReserveLtvInvariant.selector,
      IMockL2Pool.liquidationCall.selector
    );

    // Register triggers for liquidity index invariant
    registerCallTrigger(this.assertLiquidityIndexInvariant.selector, IMockL2Pool.supply.selector);
    registerCallTrigger(this.assertLiquidityIndexInvariant.selector, IMockL2Pool.withdraw.selector);
    registerCallTrigger(this.assertLiquidityIndexInvariant.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertLiquidityIndexInvariant.selector, IMockL2Pool.repay.selector);
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_A: debtToken totalSupply should be equal to the sum of all user balances (user debt)
        This is verified by ensuring that the sum of individual balance changes matches the total supply change
        for a specific asset
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertDebtTokenSupply() external {
    // Get the exact selectors for the L2Pool functions
    bytes4 l2PoolBorrowSelector = bytes4(keccak256('borrow(bytes32)'));
    bytes4 l2PoolRepaySelector = bytes4(keccak256('repay(bytes32)'));
    bytes4 l2PoolLiquidationCallSelector = bytes4(keccak256('liquidationCall(bytes32,bytes32)'));

    // Get all operations that affect debt token supply
    PhEvm.CallInputs[] memory borrowCalls = ph.getCallInputs(address(pool), l2PoolBorrowSelector);
    PhEvm.CallInputs[] memory repayCalls = ph.getCallInputs(address(pool), l2PoolRepaySelector);
    PhEvm.CallInputs[] memory liquidationCalls = ph.getCallInputs(
      address(pool),
      l2PoolLiquidationCallSelector
    );

    uint256 totalIncrease = 0;
    uint256 totalDecrease = 0;

    // Process borrow operations (increase debt) - only VARIABLE mode affects variable debt token
    for (uint256 i = 0; i < borrowCalls.length; i++) {
      bytes32 args = abi.decode(borrowCalls[i].input, (bytes32));

      // Currently if there's a delegate call, two calls are added to the array
      // We skip one of the calls here
      if (borrowCalls[i].bytecode_address != borrowCalls[i].target_address) {
        continue;
      }

      // Decode using the same logic as CalldataLogic.decodeBorrowParams
      uint16 assetId;
      uint256 amount;
      uint256 interestRateMode;
      uint16 referralCode;

      assembly {
        assetId := and(args, 0xFFFF)
        amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        interestRateMode := and(shr(144, args), 0xFF)
        referralCode := and(shr(152, args), 0xFFFF)
      }

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);

      if (
        asset == targetAsset && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
        totalIncrease += amount;
      }
    }

    // Process repay operations (decrease debt) - only VARIABLE mode affects variable debt token
    for (uint256 i = 0; i < repayCalls.length; i++) {
      bytes32 args = abi.decode(repayCalls[i].input, (bytes32));
      if (repayCalls[i].bytecode_address != repayCalls[i].target_address) {
        continue;
      }

      // Decode using the same logic as CalldataLogic.decodeRepayParams
      uint16 assetId;
      uint256 amount;
      uint256 interestRateMode;

      assembly {
        assetId := and(args, 0xFFFF)
        amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        interestRateMode := and(shr(144, args), 0xFF)
      }

      if (amount == type(uint128).max) {
        amount = type(uint256).max;
      }

      address asset = pool.getReserveAddressById(assetId);
      if (
        asset == targetAsset && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
        totalDecrease += amount;
      }
    }

    // Process liquidation operations (decrease debt)
    for (uint256 i = 0; i < liquidationCalls.length; i++) {
      if (liquidationCalls[i].bytecode_address != liquidationCalls[i].target_address) {
        continue;
      }

      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, bytes32 args2) = abi.decode(liquidationCalls[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 debtAssetId = uint16(uint256(args1) >> 16);
      uint256 debtToCover = uint256(uint128(uint256(args2)));

      address asset = pool.getReserveAddressById(debtAssetId);
      if (asset == targetAsset) {
        totalDecrease += debtToCover;
      }
    }

    // Calculate net change in debt token supply (using signed integers to handle underflow)
    int256 netDebtChange = int256(totalIncrease) - int256(totalDecrease);

    // Compare calculated debt changes with actual on-chain debt token supply
    // Get the variable debt token for this asset
    address variableDebtToken = pool.getReserveData(targetAsset).variableDebtTokenAddress;

    IERC20 debtToken = IERC20(variableDebtToken);

    // Get pre and post state of debt token total supply
    ph.forkPreState();
    uint256 preDebtSupply = debtToken.totalSupply();

    ph.forkPostState();
    uint256 postDebtSupply = debtToken.totalSupply();

    int256 actualDebtSupplyChange = int256(postDebtSupply) - int256(preDebtSupply);

    // The calculated net debt change should match the actual debt token supply change
    // Note: Proxy call filtering has been applied to handle delegate call double counting
    require(
      netDebtChange == actualDebtSupplyChange,
      'Calculated debt change does not match actual debt token supply change'
    );
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_B: aToken totalSupply should be equal to the sum of all user balances
        This ensures that the aToken supply accurately represents the total user deposits
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertATokenSupply() external {
    // Get all operations that affect aToken supply
    PhEvm.CallInputs[] memory supplyCalls = ph.getCallInputs(address(pool), pool.supply.selector);
    PhEvm.CallInputs[] memory withdrawCalls = ph.getCallInputs(
      address(pool),
      pool.withdraw.selector
    );
    PhEvm.CallInputs[] memory liquidationCalls = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );

    uint256 totalIncrease = 0;
    uint256 totalDecrease = 0;

    // Process supply operations (increase aToken supply)
    for (uint256 i = 0; i < supplyCalls.length; i++) {
      bytes32 args = abi.decode(supplyCalls[i].input, (bytes32));

      // Currently if there's a delegate call, two calls are added to the array
      // We skip one of the calls here
      if (supplyCalls[i].bytecode_address != supplyCalls[i].target_address) {
        continue;
      }

      // Decode L2Pool supply parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      address asset = pool.getReserveAddressById(assetId);
      if (asset == targetAsset) {
        totalIncrease += amount;
      }
    }

    // Process withdraw operations (decrease aToken supply)
    for (uint256 i = 0; i < withdrawCalls.length; i++) {
      bytes32 args = abi.decode(withdrawCalls[i].input, (bytes32));
      if (withdrawCalls[i].bytecode_address != withdrawCalls[i].target_address) {
        continue;
      }

      // Decode L2Pool withdraw parameters: assetId (16 bits) + amount (128 bits) + to (160 bits)
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      address asset = pool.getReserveAddressById(assetId);
      if (asset == targetAsset) {
        totalDecrease += amount;
      }
    }

    // Process liquidation operations (may affect aToken supply)
    for (uint256 i = 0; i < liquidationCalls.length; i++) {
      if (liquidationCalls[i].bytecode_address != liquidationCalls[i].target_address) {
        continue;
      }

      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, bytes32 args2) = abi.decode(liquidationCalls[i].input, (bytes32, bytes32));

      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 collateralAssetId = uint16(uint256(args1));
      uint256 debtToCover = uint256(uint128(uint256(args2)));
      bool receiveAToken = (uint256(args2) >> 128) & 1 == 1;

      address asset = pool.getReserveAddressById(collateralAssetId);
      if (asset == targetAsset && !receiveAToken) {
        // If not receiving aToken, collateral is withdrawn, decreasing aToken supply
        totalDecrease += debtToCover;
      }
    }

    // Calculate net change in aToken supply (using signed integers to handle underflow)
    int256 netATokenChange = int256(totalIncrease) - int256(totalDecrease);

    // Get the aToken for this asset
    address aTokenAddress = pool.getReserveData(targetAsset).aTokenAddress;
    require(aTokenAddress != address(0), 'AToken address is zero');

    IERC20 aToken = IERC20(aTokenAddress);

    // Get pre and post state of aToken total supply
    ph.forkPreState();
    uint256 preATokenSupply = aToken.totalSupply();

    ph.forkPostState();
    uint256 postATokenSupply = aToken.totalSupply();

    int256 actualATokenSupplyChange = int256(postATokenSupply) - int256(preATokenSupply);

    // The calculated net aToken change should match the actual aToken supply change
    require(
      netATokenChange == actualATokenSupplyChange,
      'Calculated aToken change does not match actual aToken supply change'
    );
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_C: The total amount of underlying in the protocol should be greater or equal 
        than the aToken totalSupply - debtToken totalSupply
        This ensures the protocol has sufficient underlying assets to cover net user positions
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertUnderlyingBalanceInvariant() external {
    // Get reserve data for the target asset
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(targetAsset);

    address aTokenAddress = reserveData.aTokenAddress;
    address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;

    require(aTokenAddress != address(0), 'AToken address is zero');
    require(variableDebtTokenAddress != address(0), 'Variable debt token address is zero');

    IERC20 aToken = IERC20(aTokenAddress);
    IERC20 variableDebtToken = IERC20(variableDebtTokenAddress);
    IERC20 underlying = IERC20(targetAsset);

    // Get pre and post state
    ph.forkPreState();
    uint256 preATokenSupply = aToken.totalSupply();
    uint256 preDebtTokenSupply = variableDebtToken.totalSupply();
    uint256 preUnderlyingBalance = underlying.balanceOf(aTokenAddress);

    ph.forkPostState();
    uint256 postATokenSupply = aToken.totalSupply();
    uint256 postDebtTokenSupply = variableDebtToken.totalSupply();
    uint256 postUnderlyingBalance = underlying.balanceOf(aTokenAddress);

    // Calculate net liability (aToken supply - debt token supply)
    // If aToken supply > debt token supply, net liability is positive
    // If debt token supply >= aToken supply, net liability is 0
    uint256 preNetLiability = preATokenSupply > preDebtTokenSupply
      ? preATokenSupply - preDebtTokenSupply
      : 0;
    uint256 postNetLiability = postATokenSupply > postDebtTokenSupply
      ? postATokenSupply - postDebtTokenSupply
      : 0;

    // BASE_INVARIANT_C: The underlying balance should be >= net liability
    // This ensures the protocol has sufficient underlying assets to cover net user positions
    require(
      postUnderlyingBalance >= postNetLiability,
      'BASE_INVARIANT_C: Underlying balance insufficient to cover net liability'
    );

    // Additional validation: If the underlying balance decreased, ensure it's still sufficient
    // This prevents the protocol from losing more underlying assets than it can afford
    if (postUnderlyingBalance < preUnderlyingBalance) {
      uint256 underlyingBalanceDecrease = preUnderlyingBalance - postUnderlyingBalance;
      uint256 netLiabilityDecrease = preNetLiability > postNetLiability
        ? preNetLiability - postNetLiability
        : 0;

      // The underlying balance decrease should not exceed the net liability decrease
      // This ensures the protocol doesn't lose more assets than the reduction in liability
      require(
        underlyingBalanceDecrease <= netLiabilityDecrease,
        'BASE_INVARIANT_C: Underlying balance decreased more than net liability reduction'
      );
    }
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_D: The total amount of underlying in the protocol should be greater or equal 
        to the reserve virtualUnderlyingBalance
        This ensures the protocol maintains sufficient real underlying assets
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertVirtualBalanceInvariant() external {
    // Get reserve data for the target asset
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(targetAsset);

    address aTokenAddress = reserveData.aTokenAddress;
    require(aTokenAddress != address(0), 'AToken address is zero');

    IERC20 aToken = IERC20(aTokenAddress);
    IERC20 underlying = IERC20(targetAsset);

    // Get pre and post state
    ph.forkPreState();
    uint256 preUnderlyingBalance = underlying.balanceOf(aTokenAddress);
    uint256 preVirtualBalance = pool.getVirtualUnderlyingBalance(targetAsset);

    ph.forkPostState();
    uint256 postUnderlyingBalance = underlying.balanceOf(aTokenAddress);
    uint256 postVirtualBalance = pool.getVirtualUnderlyingBalance(targetAsset);

    // The actual underlying balance should be >= virtual underlying balance
    // This ensures the protocol has sufficient real assets to cover its accounting
    require(
      postUnderlyingBalance >= postVirtualBalance,
      'Actual underlying balance is less than virtual underlying balance'
    );

    // Additional check: if virtual balance increases, actual balance should not decrease
    // This prevents the protocol from losing real assets while increasing virtual accounting
    if (postVirtualBalance > preVirtualBalance) {
      require(
        postUnderlyingBalance >= preUnderlyingBalance,
        'Virtual balance increased but actual balance decreased'
      );
    }
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_E: If reserve is frozen pending ltv cannot be 0
        This ensures that when a reserve is frozen, there must be a pending LTV change
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertFrozenReserveLtvInvariant() external {
    // Get reserve configuration to check if frozen
    DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(targetAsset);

    // Check if reserve is frozen
    if (config.getFrozen()) {
      // If reserve is frozen, pending LTV should not be 0
      // This ensures there's a pending configuration change
      uint256 pendingLtv = pool.getPendingLtv(targetAsset);
      require(pendingLtv != 0, 'BASE_INVARIANT_E: Frozen reserve has no pending LTV change');
    }
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_F: virtualBalance + currentDebt = (scaledATokenTotalSupply + accrueToTreasury) * liquidityIndexRightNow
        This is the core accounting invariant that ensures proper interest accrual
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertLiquidityIndexInvariant() external {
    // Get reserve data for the target asset
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(targetAsset);

    address aTokenAddress = reserveData.aTokenAddress;
    address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;

    require(aTokenAddress != address(0), 'AToken address is zero');
    require(variableDebtTokenAddress != address(0), 'Variable debt token address is zero');

    IERC20 aToken = IERC20(aTokenAddress);
    IERC20 variableDebtToken = IERC20(variableDebtTokenAddress);

    // Get virtual balance and current debt
    uint256 virtualBalance = pool.getVirtualUnderlyingBalance(targetAsset);
    uint256 currentDebt = variableDebtToken.totalSupply();

    // Calculate left side: virtualBalance + currentDebt
    uint256 leftSide = virtualBalance + currentDebt;

    // Calculate right side: (scaledATokenTotalSupply + accruedToTreasury) * liquidityIndex
    // Note: aToken.totalSupply() already includes the liquidity index multiplication
    // So we need to get the scaled total supply and multiply by the normalized income
    uint256 scaledATokenTotalSupply = IScaledBalanceToken(aTokenAddress).scaledTotalSupply();
    uint256 accruedToTreasury = reserveData.accruedToTreasury;

    // Get the normalized income (liquidity index)
    uint256 normalizedIncome = pool.getReserveNormalizedIncome(targetAsset);

    // Calculate right side: (scaledATokenTotalSupply + accruedToTreasury) * normalizedIncome
    uint256 rightSide = WadRayMath.rayMul(
      scaledATokenTotalSupply + accruedToTreasury,
      normalizedIncome
    );

    // Allow for small rounding differences (10 wei tolerance as in the test)
    uint256 difference = leftSide > rightSide ? leftSide - rightSide : rightSide - leftSide;
    require(difference <= 10, 'Liquidity index invariant violated');
  }
}
