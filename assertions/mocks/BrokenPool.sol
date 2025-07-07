// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {MockERC20} from './MockERC20.sol';

contract BrokenPool is IMockL2Pool {
  // Store user debt amounts
  mapping(address => uint256) public userDebt;

  // Store user balances
  mapping(address => mapping(address => uint256)) public userBalances;

  // Store health factors
  mapping(address => uint256) public userHealthFactors;

  // Store aToken addresses
  mapping(address => address) public aTokenAddresses;

  // Configuration flags
  bool public breakDepositBalance;
  bool public breakRepayDebt;
  bool public breakWithdrawBalance;
  bool public breakFlashloanRepayment;

  // BaseInvariants violation flags
  bool public breakDebtTokenSupply;
  bool public breakATokenSupply;
  bool public breakUnderlyingBalance;
  bool public breakVirtualBalance;
  bool public breakLiquidityIndex;

  // Token addresses for BaseInvariants testing
  mapping(address => address) public variableDebtTokenAddresses;
  mapping(address => uint256) public liquidityIndices;
  mapping(address => uint256) public accruedToTreasury;

  // Simple state tracking
  mapping(address => bool) public isActive;
  mapping(address => bool) public isFrozen;
  mapping(address => bool) public isPaused;

  // Liquidation state
  mapping(address => uint40) public liquidationGracePeriods;
  mapping(address => uint256) public reserveDeficits;

  // Mock token implementations for BaseInvariants testing
  mapping(address => uint256) public mockATokenSupply;
  mapping(address => uint256) public mockDebtTokenSupply;
  mapping(address => uint256) public mockUnderlyingBalance;
  mapping(address => MockERC20) public mockATokens;
  mapping(address => MockERC20) public mockDebtTokens;
  mapping(address => MockERC20) public mockUnderlyings;

  function setATokenAddress(address asset, address aToken) external {
    aTokenAddresses[asset] = aToken;
  }

  function setUserDebt(address user, uint256 amount) external {
    userDebt[user] = amount;
  }

  function setBreakDepositBalance(bool value) external {
    breakDepositBalance = value;
  }

  function setBreakRepayDebt(bool value) external {
    breakRepayDebt = value;
  }

  function setBreakWithdrawBalance(bool value) external {
    breakWithdrawBalance = value;
  }

  function setBreakFlashloanRepayment(bool value) external {
    breakFlashloanRepayment = value;
  }

  function setBreakDebtTokenSupply(bool value) external {
    breakDebtTokenSupply = value;
  }

  function setBreakATokenSupply(bool value) external {
    breakATokenSupply = value;
  }

  function setBreakUnderlyingBalance(bool value) external {
    breakUnderlyingBalance = value;
  }

  function setBreakVirtualBalance(bool value) external {
    breakVirtualBalance = value;

    // If setting breakVirtualBalance to true, ensure all underlying tokens have low balances
    // This will make actual balance < virtual balance, violating the invariant
    if (value) {
      // Update all created mock tokens
      address[] memory assets = new address[](2);
      assets[0] = address(0x1);
      assets[1] = address(0x2);

      for (uint256 i = 0; i < assets.length; i++) {
        address asset = assets[i];
        if (
          address(mockUnderlyings[asset]) != address(0) && address(mockATokens[asset]) != address(0)
        ) {
          mockUnderlyings[asset].setBalance(address(mockATokens[asset]), 100e6); // Low actual balance
        }
      }
    }
  }

  function setBreakLiquidityIndex(bool value) external {
    breakLiquidityIndex = value;
  }

  function setVariableDebtTokenAddress(address asset, address debtToken) external {
    variableDebtTokenAddresses[asset] = debtToken;
  }

  function setLiquidityIndex(address asset, uint256 index) external {
    liquidityIndices[asset] = index;

    // If setting liquidity index to 0, this should violate the invariant
    // The invariant requires liquidity index >= 1e27
    if (index == 0) {
      // Manipulate the mock tokens to create a violation
      // Set aToken supply to a very high value while keeping debt token supply low
      // This will make the calculation fail
      if (address(mockATokens[asset]) != address(0)) {
        mockATokens[asset].setTotalSupply(1000e6); // High aToken supply
      }
      if (address(mockDebtTokens[asset]) != address(0)) {
        mockDebtTokens[asset].setTotalSupply(1e6); // Low debt token supply
      }
    }
  }

  function setAccruedToTreasury(address asset, uint256 amount) external {
    accruedToTreasury[asset] = amount;
  }

  function setUserHealthFactor(address user, uint256 healthFactor) external {
    userHealthFactors[user] = healthFactor;
  }

  // Simple state control functions
  function setReserveActive(address asset, bool active) external {
    isActive[asset] = active;
  }

  function setReserveFrozen(address asset, bool frozen) external {
    isFrozen[asset] = frozen;
  }

  function setReservePaused(address asset, bool paused) external {
    isPaused[asset] = paused;
  }

  function supply(bytes32 args) external {
    uint16 assetId = uint16(uint256(args));
    uint256 amount = uint256(uint128(uint256(args) >> 16));
    address asset = getAssetAddressById(assetId);

    if (breakATokenSupply) {
      // Set aToken supply to a value that is always wrong (e.g., 42)
      if (address(mockATokens[asset]) != address(0)) {
        mockATokens[asset].setTotalSupply(42);
      }
    } else if (breakUnderlyingBalance) {
      // Set underlying balance to a value that violates the invariant
      // The invariant requires: underlying balance >= (aToken supply - debt token supply)
      // Set aToken supply to 100 and underlying balance to 50, so 50 < (100 - 0) = 100
      if (address(mockATokens[asset]) != address(0)) {
        mockATokens[asset].setTotalSupply(100);
      }
      if (address(mockUnderlyings[asset]) != address(0)) {
        mockUnderlyings[asset].setBalance(address(mockATokens[asset]), 50);
      }
      userBalances[msg.sender][asset] += amount;
    } else if (breakDepositBalance) {
      userBalances[msg.sender][asset] += amount - 1;
    } else {
      userBalances[msg.sender][asset] += amount;
    }
  }

  // Note: The virtual balance invariant is currently a no-op in the assertion contract, so the test will always fail until implemented.

  function repay(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    if (!breakRepayDebt) {
      // Normal behavior - decrease debt
      if (userDebt[msg.sender] >= amount) {
        userDebt[msg.sender] -= amount;
      } else {
        userDebt[msg.sender] = 0; // Prevent underflow
      }
    } else {
      // Broken behavior: decrease debt but by wrong amount (off by 1 wei)
      uint256 amountToRepay = amount > 1 ? amount - 1 : 0;
      if (userDebt[msg.sender] >= amountToRepay) {
        userDebt[msg.sender] -= amountToRepay;
      } else {
        userDebt[msg.sender] = 0; // Prevent underflow
      }
    }
    return amount;
  }

  function repay(address, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
    if (!breakRepayDebt) {
      // Normal behavior - decrease debt
      if (userDebt[onBehalfOf] >= amount) {
        userDebt[onBehalfOf] -= amount;
      } else {
        userDebt[onBehalfOf] = 0; // Prevent underflow
      }
    } else {
      // Broken behavior: decrease debt but by wrong amount (off by 1 wei)
      uint256 amountToRepay = amount > 1 ? amount - 1 : 0;
      if (userDebt[onBehalfOf] >= amountToRepay) {
        userDebt[onBehalfOf] -= amountToRepay;
      } else {
        userDebt[onBehalfOf] = 0; // Prevent underflow
      }
    }
    return amount;
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
    return (0, userDebt[user], 0, 0, 0, userHealthFactors[user]);
  }

  function getReserveData(
    address asset
  ) external view returns (DataTypes.ReserveDataLegacy memory) {
    DataTypes.ReserveDataLegacy memory data;
    // Create a simple configuration that matches our state
    data.configuration.data = 0;
    if (isActive[asset]) {
      data.configuration.data |= 1 << 56; // ACTIVE_MASK position
    }
    if (isFrozen[asset]) {
      data.configuration.data |= 1 << 57; // FROZEN_MASK position
    }
    if (isPaused[asset]) {
      data.configuration.data |= 1 << 60; // PAUSED_MASK position
    }

    // Set token addresses for BaseInvariants testing
    data.aTokenAddress = aTokenAddresses[asset];
    data.variableDebtTokenAddress = variableDebtTokenAddresses[asset];

    // Set liquidity index and accrued to treasury
    data.liquidityIndex = uint128(liquidityIndices[asset]);
    data.accruedToTreasury = uint128(accruedToTreasury[asset]);

    // Set the asset ID for L2Encoder compatibility
    // Map asset addresses to IDs: address(0x2) -> 2, address(0x1) -> 1
    if (asset == address(0x2)) {
      data.id = 2;
    } else if (asset == address(0x1)) {
      data.id = 1;
    } else {
      data.id = 0;
    }

    return data;
  }

  function borrow(bytes32 args) external {
    // Decode parameters (simplified)
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

    if (breakDebtTokenSupply) {
      // Broken behavior: don't update user debt at all (violates debt token supply invariant)
      // This will cause the debt token supply to not match individual user debt changes
    } else {
      // Specific bug: when borrowing exactly 333e6, double the amount
      if (amount == 333e6) {
        userDebt[msg.sender] += amount * 2; // Double the debt
      } else {
        userDebt[msg.sender] += amount; // Normal behavior
      }
    }
  }

  function withdraw(address asset, uint256 amount, address) external returns (uint256) {
    if (!breakWithdrawBalance) {
      // Normal behavior - update balances
      if (userBalances[msg.sender][asset] >= amount) {
        userBalances[msg.sender][asset] -= amount;
      } else {
        userBalances[msg.sender][asset] = 0; // Prevent underflow
      }
    } else {
      // Broken behavior: update balance but with wrong amount (off by 1 wei)
      uint256 amountToWithdraw = amount > 1 ? amount - 1 : 0;
      if (userBalances[msg.sender][asset] >= amountToWithdraw) {
        userBalances[msg.sender][asset] -= amountToWithdraw;
      } else {
        userBalances[msg.sender][asset] = 0; // Prevent underflow
      }
    }
    return amount;
  }

  // L2Pool function implementations
  function supplyWithPermit(bytes32 args, bytes32, bytes32) external {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard supply function
    this.supply(args);
  }

  function withdraw(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // Broken behavior: update balance but with wrong amount (off by 1 wei)
    uint256 amountToWithdraw = amount > 1 ? amount - 1 : 0;
    if (userBalances[msg.sender][address(0)] >= amountToWithdraw) {
      userBalances[msg.sender][address(0)] -= amountToWithdraw;
    } else {
      userBalances[msg.sender][address(0)] = 0; // Prevent underflow
    }
    return amount;
  }

  function repayWithPermit(bytes32 args, bytes32, bytes32) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the L2Pool repay function
    return this.repay(args);
  }

  function repayWithATokens(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the L2Pool repay function
    return this.repay(args);
  }

  function setUserUseReserveAsCollateral(bytes32 args) external {
    // No-op for testing
  }

  function liquidationCall(bytes32 args1, bytes32 args2) external {
    // Decode L2Pool liquidation parameters:
    // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
    // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
    uint16 collateralAssetId = uint16(uint256(args1));
    uint16 debtAssetId = uint16(uint256(args1) >> 16);
    address user = address(uint160(uint256(args1) >> 32));
    uint256 debtToCover = uint256(uint128(uint256(args2)));

    // Get current user state
    uint256 currentDebt = userDebt[user];
    address collateralAsset = getAssetAddressById(collateralAssetId);
    address debtAsset = getAssetAddressById(debtAssetId);
    uint256 currentCollateral = userBalances[user][collateralAsset];

    // Ensure we have valid debt to work with
    if (currentDebt == 0) {
      return; // No debt to liquidate
    }

    // Calculate how much debt to burn (don't exceed current debt)
    uint256 debtToBurn = debtToCover > currentDebt ? currentDebt : debtToCover;

    // Ensure we don't underflow
    if (userDebt[user] >= debtToBurn) {
      userDebt[user] -= debtToBurn;
    } else {
      userDebt[user] = 0; // Prevent underflow
    }

    // Implement specific broken behaviors for different test scenarios
    // Each test should trigger a different violation

    // For deficit creation test: create deficit while user still has collateral
    // This will be triggered by specific test setup where user has both debt and collateral
    if (currentDebt > 0 && currentCollateral > 0 && userDebt[user] == 0) {
      // User has no debt left but still has collateral - this violates deficit creation rule
      // The assertion should catch this
    }

    // For deficit accounting test: update reserve deficit but with wrong amount
    if (debtToBurn > 0) {
      // Update deficit but with wrong amount (off by 1 wei)
      reserveDeficits[debtAsset] += debtToBurn - 1;
    }

    // For deficit amount test: set deficit to wrong amount
    if (userDebt[user] > 0) {
      reserveDeficits[debtAsset] = userDebt[user] / 2; // Set deficit to half of remaining debt
    }

    // For active reserve deficit test: create deficit on inactive reserve
    if (userDebt[user] > 0 && !isActive[debtAsset]) {
      reserveDeficits[debtAsset] = userDebt[user];
    }

    // For liquidation amounts test: leave insufficient leftover
    if (userDebt[user] > 0 && userDebt[user] < 100e18) {
      userDebt[user] = 1; // Set to 1 wei (much less than MIN_LEFTOVER_BASE)
    }
  }

  // Helper function to map asset IDs to addresses for testing
  function getAssetAddressById(uint16 assetId) internal pure returns (address) {
    // For testing purposes, we'll use a simple mapping
    // In a real implementation, this would query the actual pool
    if (assetId == 1) return address(0x1); // collateral asset
    if (assetId == 2) return address(0x2); // debt asset (matches test asset)
    return address(0);
  }

  // Required IPool interface functions - return empty/default values
  function initReserve(
    address asset,
    address aTokenAddress,
    address stableDebtAddress,
    address variableDebtAddress,
    address interestRateStrategyAddress
  ) external {}

  function dropReserve(address asset) external {}

  function setReserveInterestRateStrategyAddress(
    address asset,
    address rateStrategyAddress
  ) external {}

  function setConfiguration(
    address asset,
    DataTypes.ReserveConfigurationMap calldata configuration
  ) external {}

  function getConfiguration(
    address
  ) external pure returns (DataTypes.ReserveConfigurationMap memory) {
    return DataTypes.ReserveConfigurationMap(0);
  }

  function getUserConfiguration(
    address
  ) external pure returns (DataTypes.UserConfigurationMap memory) {
    return DataTypes.UserConfigurationMap(0);
  }

  function getReserveNormalizedIncome(address) external pure returns (uint256) {
    return 1e27;
  }

  function getReserveNormalizedVariableDebt(address) external pure returns (uint256) {
    return 1e27;
  }

  function finalizeTransfer(
    address asset,
    address from,
    address to,
    uint256 amount,
    uint256 balanceFromBefore,
    uint256 balanceToBefore
  ) external {}

  function getReservesList() external pure returns (address[] memory) {
    return new address[](0);
  }

  function getReserveAddressById(uint16 assetId) external pure returns (address) {
    // For testing purposes, we'll use a simple mapping
    // In a real implementation, this would query the actual pool
    if (assetId == 1) return address(0x1); // collateral asset
    if (assetId == 2) return address(0x2); // debt asset
    return address(0);
  }

  function getAddressesProvider() external pure returns (address) {
    return address(0);
  }

  function setPause(bool val) external {}

  function getPaused() external pure returns (bool) {
    return false;
  }

  function getCloseFactor() external pure returns (uint256) {
    return 5000; // 50%
  }

  function MIN_BASE_MAX_CLOSE_FACTOR_THRESHOLD() external pure returns (uint256) {
    return 1000e18;
  }

  function MIN_LEFTOVER_BASE() external pure returns (uint256) {
    return 100e18;
  }

  function getUserCollateralBalance(address user, address asset) external view returns (uint256) {
    return userBalances[user][asset];
  }

  function getUserDebtBalance(address user, address) external view returns (uint256) {
    return userDebt[user];
  }

  function getReserveDeficit(address asset) external view returns (uint256) {
    return reserveDeficits[asset];
  }

  function getVirtualUnderlyingBalance(address asset) external view returns (uint128) {
    // Return a mock virtual balance for testing
    // For testing violations, we can return different values based on the asset
    if (breakVirtualBalance) {
      // Return a very high virtual balance that will violate the invariant
      // This will make virtual balance > actual balance, violating the invariant
      return 10000e6; // 10,000 tokens (much higher than actual balance)
    }

    if (asset == address(0x2)) {
      // Return a high virtual balance that might violate the invariant
      return 1000e6; // 1000 tokens
    }
    return 100e6; // Default virtual balance
  }

  function getLiquidationGracePeriod(address asset) external view returns (uint40) {
    return liquidationGracePeriods[asset];
  }

  // Helper functions for testing
  function setLiquidationGracePeriod(address asset, uint40 until) external {
    liquidationGracePeriods[asset] = until;
  }

  function setReserveDeficit(address asset, uint256 deficit) external {
    reserveDeficits[asset] = deficit;
  }

  // Flashloan implementation that can be broken
  function flashLoan(
    address receiverAddress,
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata,
    address,
    bytes calldata,
    uint16
  ) external {
    if (breakFlashloanRepayment) {
      // Broken behavior: Transfer tokens but don't require repayment
      for (uint256 i = 0; i < assets.length; i++) {
        IERC20(assets[i]).transfer(receiverAddress, amounts[i]);
      }
    }
    // Not broken behavior: Do nothing, pretending no state has changed
  }

  // Simple flashloan implementation that can be broken
  function flashLoanSimple(
    address receiverAddress,
    address asset,
    uint256 amount,
    bytes calldata,
    uint16
  ) external {
    if (breakFlashloanRepayment) {
      // Broken behavior: Transfer tokens but don't require repayment
      IERC20(asset).transfer(receiverAddress, amount);
    }
    // Not broken behavior: Do nothing, pretending no state has changed
  }

  function setUserBalances(address user, address asset, uint256 amount) external {
    userBalances[user][asset] = amount;
  }

  function setMockATokenSupplyAmount(address asset, uint256 supplyAmount) external {
    mockATokenSupply[asset] = supplyAmount;
  }

  function setMockDebtTokenSupplyAmount(address asset, uint256 supplyAmount) external {
    mockDebtTokenSupply[asset] = supplyAmount;
  }

  function setMockUnderlyingBalance(address asset, uint256 balance) external {
    mockUnderlyingBalance[asset] = balance;
  }

  function getMockUnderlying(address asset) external view returns (MockERC20) {
    return mockUnderlyings[asset];
  }

  // Functions to manipulate mock tokens for testing
  function manipulateATokenSupply(address asset, uint256 newSupply) external {
    mockATokens[asset].setTotalSupply(newSupply);
  }

  function manipulateDebtTokenSupply(address asset, uint256 newSupply) external {
    mockDebtTokens[asset].setTotalSupply(newSupply);
  }

  function manipulateUnderlyingBalance(address asset, uint256 newBalance) external {
    mockUnderlyings[asset].setBalance(address(this), newBalance);
  }

  function createMockTokens(address asset) external {
    if (address(mockATokens[asset]) == address(0)) {
      mockATokens[asset] = new MockERC20('Mock AToken', 'maTOKEN', 6);
      mockDebtTokens[asset] = new MockERC20('Mock Debt Token', 'mDEBT', 6);
      mockUnderlyings[asset] = new MockERC20('Mock Underlying', 'mUNDER', 6);

      // Set this contract as controller
      mockATokens[asset].setController(address(this));
      mockDebtTokens[asset].setController(address(this));
      mockUnderlyings[asset].setController(address(this));

      // Set token addresses
      aTokenAddresses[asset] = address(mockATokens[asset]);
      variableDebtTokenAddresses[asset] = address(mockDebtTokens[asset]);

      // If breakVirtualBalance is set, ensure the underlying token has a low balance
      // This will make actual balance < virtual balance, violating the invariant
      if (breakVirtualBalance) {
        mockUnderlyings[asset].setBalance(address(mockATokens[asset]), 100e6); // Low actual balance
      } else {
        mockUnderlyings[asset].setBalance(address(mockATokens[asset]), 1000e6); // Normal balance
      }
    }
  }

  function setActive(address asset, bool value) external {
    isActive[asset] = value;
  }

  function setFrozen(address asset, bool value) external {
    isFrozen[asset] = value;
  }

  function setPaused(address asset, bool value) external {
    isPaused[asset] = value;
  }
}
