// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title BorrowingInvariantAssertions Tests
 * @notice This test file uses the real Aave V3 protocol to verify that our assertions
 *         correctly pass when the protocol behaves as expected. It ensures that our
 *         assertions don't revert when they shouldn't, validating that our invariant
 *         checks are not overly restrictive.
 *
 *         For example, it verifies that the liability decrease assertion passes when
 *         a user successfully repays their debt, as the real protocol correctly
 *         decreases the user's debt.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BaseInvariants} from '../src/production/BaseInvariants.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';

contract TestDebtSumInvariant is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  BaseInvariants public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  string public constant ASSERTION_LABEL = 'DebtSumInvariant';

  function setUp() public {
    // Initialize test environment with real contracts (L2 enabled for L2Encoder)
    initL2TestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockL2Pool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = L2Encoder(report.l2Encoder);

    // Deploy assertions contract
    assertions = new BaseInvariants(address(pool), asset);

    // Get variable debt token
    address variableDebtUSDX = pool.getReserveData(asset).variableDebtTokenAddress;
    variableDebtToken = IERC20(variableDebtUSDX);
  }

  function testAssertionBorrowMagicNumber() public {
    // For testing purposes, we have introduced a bug in the borrow function
    // When trying to borrow exactly 333e6, the user will receive double the amount
    // but the debt token supply will only increase by the requested amount (333e6)
    // The assertion should PASS because it correctly verifies the debt token supply change

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BaseInvariants).creationCode,
      abi.encode(address(pool), address(underlying))
    );

    // Set up fresh user with collateral
    deal(asset, user, 20000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral using L2Pool encoding
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 333e6, 2, 0);

    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionBorrowNormal() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BaseInvariants).creationCode,
      abi.encode(address(pool), address(underlying))
    );

    // Set up fresh user with collateral
    deal(asset, user, 20000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral using L2Pool encoding
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);
    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // This should NOT fail assertions because the borrow amount is not the magic number
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testBorrowInvariantManual() public {
    // Set up fresh user with collateral
    deal(asset, user, 20000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral using L2Pool encoding
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    // Get aToken address for the asset
    (address aTokenAddr, , ) = contracts.protocolDataProvider.getReserveTokensAddresses(asset);
    IERC20 aToken = IERC20(aTokenAddr);

    // --- Normal borrow: should work as expected ---
    uint256 beforeDebtTotal = variableDebtToken.totalSupply();
    uint256 beforeATokenTotal = aToken.totalSupply();
    uint256 beforeUserBalance = underlying.balanceOf(user);
    emit log_named_uint('aToken totalSupply before normal borrow', beforeATokenTotal);
    emit log_named_uint('DebtToken totalSupply before normal borrow', beforeDebtTotal);
    emit log_named_uint('User balance before normal borrow', beforeUserBalance);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);
    pool.borrow(borrowArgs);

    uint256 afterDebtTotal = variableDebtToken.totalSupply();
    uint256 afterATokenTotal = aToken.totalSupply();
    uint256 afterUserBalance = underlying.balanceOf(user);
    emit log_named_uint('aToken totalSupply after normal borrow', afterATokenTotal);
    emit log_named_uint('DebtToken totalSupply after normal borrow', afterDebtTotal);
    emit log_named_uint('User balance after normal borrow', afterUserBalance);
    emit log_named_uint('aToken delta (normal)', afterATokenTotal - beforeATokenTotal);
    emit log_named_uint('DebtToken delta (normal)', afterDebtTotal - beforeDebtTotal);
    emit log_named_uint('User balance delta (normal)', afterUserBalance - beforeUserBalance);
    assertEq(
      afterATokenTotal - beforeATokenTotal,
      0,
      'aToken totalSupply should not change on borrow'
    );
    assertEq(
      afterDebtTotal - beforeDebtTotal,
      100e6,
      'DebtToken totalSupply should increase by borrowed amount'
    );
    assertEq(
      afterUserBalance - beforeUserBalance,
      100e6,
      'User should receive exactly the borrowed amount'
    );
    assertEq(
      afterUserBalance - beforeUserBalance,
      afterDebtTotal - beforeDebtTotal,
      'User balance should be equal to debt token total supply'
    );
    vm.stopPrank();
  }

  function testBorrowInvariantMagicNumber() public {
    // Set up fresh user with collateral
    deal(asset, user, 20000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral using L2Pool encoding
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    // Get aToken address for the asset
    (address aTokenAddr, , ) = contracts.protocolDataProvider.getReserveTokensAddresses(asset);
    IERC20 aToken = IERC20(aTokenAddr);

    // --- Magic number borrow: should trigger the bug ---
    uint256 beforeDebtTotal = variableDebtToken.totalSupply();
    uint256 beforeATokenTotal = aToken.totalSupply();
    uint256 beforeUserBalance = underlying.balanceOf(user);
    emit log_named_uint('aToken totalSupply before magic borrow', beforeATokenTotal);
    emit log_named_uint('DebtToken totalSupply before magic borrow', beforeDebtTotal);
    emit log_named_uint('User balance before magic borrow', beforeUserBalance);

    // Create L2Pool compact parameters for borrow with magic number
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 333e6, 2, 0);
    pool.borrow(borrowArgs);

    uint256 afterDebtTotal = variableDebtToken.totalSupply();
    uint256 afterATokenTotal = aToken.totalSupply();
    uint256 afterUserBalance = underlying.balanceOf(user);
    emit log_named_uint('aToken totalSupply after magic borrow', afterATokenTotal);
    emit log_named_uint('DebtToken totalSupply after magic borrow', afterDebtTotal);
    emit log_named_uint('User balance after magic borrow', afterUserBalance);
    emit log_named_uint('aToken delta (magic)', afterATokenTotal - beforeATokenTotal);
    emit log_named_uint('DebtToken delta (magic)', afterDebtTotal - beforeDebtTotal);
    emit log_named_uint('User balance delta (magic)', afterUserBalance - beforeUserBalance);

    // Verify the bug: user should receive double the amount (666e6 instead of 333e6)
    assertEq(
      afterUserBalance - beforeUserBalance,
      666e6,
      'User should receive double the borrowed amount due to magic number bug'
    );

    // Verify that debt tokens still only increase by the requested amount (333e6)
    // This shows the mismatch between what the user received and what they owe
    assertEq(
      afterDebtTotal - beforeDebtTotal,
      333e6,
      'DebtToken totalSupply should only increase by requested amount despite user receiving double'
    );

    // Verify aToken total supply still doesn't change
    assertEq(
      afterATokenTotal - beforeATokenTotal,
      0,
      'aToken totalSupply should not change on borrow'
    );

    vm.stopPrank();
  }

  function testAssertionLogicManual() public {
    // Set up fresh user with collateral
    deal(asset, user, 20000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral using L2Pool encoding
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    // Get aToken address for the asset
    (address aTokenAddr, , ) = contracts.protocolDataProvider.getReserveTokensAddresses(asset);
    IERC20 aToken = IERC20(aTokenAddr);

    // --- Test the assertion logic manually ---
    uint256 beforeDebtTotal = variableDebtToken.totalSupply();
    uint256 beforeATokenTotal = aToken.totalSupply();
    uint256 beforeUserBalance = underlying.balanceOf(user);

    // Create L2Pool compact parameters for borrow with magic number
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 333e6, 2, 0);

    // Decode the parameters using the same logic as the assertion
    uint16 assetId;
    uint256 amount;
    uint256 interestRateMode;
    uint16 referralCode;

    assembly {
      assetId := and(borrowArgs, 0xFFFF)
      amount := and(shr(16, borrowArgs), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
      interestRateMode := and(shr(144, borrowArgs), 0xFF)
      referralCode := and(shr(152, borrowArgs), 0xFFFF)
    }

    // Get the asset address from the assetId using the same method as the assertion
    address decodedAsset = pool.getReserveAddressById(assetId);

    // Get the variable debt token using the same method as the assertion
    address variableDebtTokenFromPool = pool.getReserveData(decodedAsset).variableDebtTokenAddress;

    // Verify we got the correct asset and debt token
    assertEq(decodedAsset, asset, 'Decoded asset should match the original asset');
    assertEq(
      variableDebtTokenFromPool,
      address(variableDebtToken),
      'Variable debt token address should match'
    );
    assertTrue(
      variableDebtTokenFromPool != address(0),
      'Variable debt token address should not be zero'
    );

    emit log_named_address('Original asset', asset);
    emit log_named_address('Decoded asset', decodedAsset);
    emit log_named_address('Variable debt token from pool', variableDebtTokenFromPool);
    emit log_named_address('Variable debt token from setup', address(variableDebtToken));
    emit log_named_uint('Asset ID', assetId);
    emit log_named_uint('Amount', amount);
    emit log_named_uint('Interest rate mode', interestRateMode);
    emit log_named_uint('Referral code', referralCode);

    // Execute the borrow
    pool.borrow(borrowArgs);

    uint256 afterDebtTotal = variableDebtToken.totalSupply();
    uint256 afterATokenTotal = aToken.totalSupply();
    uint256 afterUserBalance = underlying.balanceOf(user);

    // Calculate the changes
    uint256 debtTokenChange = afterDebtTotal - beforeDebtTotal;
    uint256 userBalanceChange = afterUserBalance - beforeUserBalance;

    emit log_named_uint('Debt token change', debtTokenChange);
    emit log_named_uint('User balance change', userBalanceChange);
    emit log_named_uint('Expected amount from decoding', amount);

    // Verify the assertion logic: the decoded amount should match the debt token change
    // (This is what the assertion checks)
    assertEq(amount, debtTokenChange, 'Decoded amount should match debt token supply change');

    // Verify the bug: user receives double the amount but debt only increases by the requested amount
    assertEq(
      userBalanceChange,
      666e6,
      'User should receive double the borrowed amount due to magic number bug'
    );
    assertEq(debtTokenChange, 333e6, 'Debt token should only increase by the requested amount');

    vm.stopPrank();
  }
}
