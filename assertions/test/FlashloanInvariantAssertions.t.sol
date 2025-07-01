// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title FlashloanInvariantAssertions Tests
 * @notice This test file uses the real Aave V3 protocol to verify that our assertions
 *         correctly pass when flashloans are properly repaid. It ensures that our
 *         assertions don't revert when they shouldn't, validating that our invariant
 *         checks are not overly restrictive.
 *
 *         For example, it verifies that the flashloan repayment assertion passes when
 *         a user successfully executes a flashloan and repays it with the required fee,
 *         as the real protocol correctly handles the token transfers and balance updates.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {FlashloanPostConditionAssertions} from '../src/FlashloanInvariantAssertions.a.sol';
import {IMockL2Pool} from '../src/IMockL2Pool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {TestnetERC20} from '../../src/contracts/mocks/testnet-helpers/TestnetERC20.sol';
import {MockFlashLoanReceiver} from '../../src/contracts/mocks/flashloan/MockFlashLoanReceiver.sol';
import {MockFlashLoanSimpleReceiver} from '../../src/contracts/mocks/flashloan/MockSimpleFlashLoanReceiver.sol';
import {IPoolAddressesProvider} from '../../src/contracts/interfaces/IPoolAddressesProvider.sol';
import {ReserveConfiguration} from '../../src/contracts/protocol/pool/PoolConfigurator.sol';

contract TestFlashloanInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  FlashloanPostConditionAssertions public assertions;
  address public user;
  address public asset;
  IERC20 public underlying;
  string public constant ASSERTION_LABEL = 'FlashloanInvariantAssertions';
  MockFlashLoanReceiver internal mockFlashReceiver;
  MockFlashLoanSimpleReceiver internal mockFlashSimpleReceiver;

  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  function setUp() public {
    // Initialize test environment with real contracts (L2 enabled for L2Encoder)
    initL2TestEnvironment();

    asset = tokenList.usdx;
    // Supply tokens to the pool first, like in the original test
    vm.prank(carol);
    contracts.poolProxy.supply(tokenList.usdx, 50_000e6, carol, 0);
    vm.prank(carol);
    contracts.poolProxy.supply(tokenList.wbtc, 20e8, carol, 0);

    mockFlashReceiver = new MockFlashLoanReceiver(
      IPoolAddressesProvider(report.poolAddressesProvider)
    );
    mockFlashSimpleReceiver = new MockFlashLoanSimpleReceiver(
      IPoolAddressesProvider(report.poolAddressesProvider)
    );
  }

  function testAssertionFlashloanRepayment() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(contracts.poolProxy),
      type(FlashloanPostConditionAssertions).creationCode,
      abi.encode(IMockL2Pool(address(contracts.poolProxy)))
    );

    // Transfer ownership of the token to the mock receiver
    vm.prank(poolAdmin);
    TestnetERC20(asset).transferOwnership(address(mockFlashSimpleReceiver));

    uint256 amount = 12e6;

    bytes memory emptyParams;

    // Execute flashloan through cl.validate
    vm.prank(alice);
    cl.validate(
      ASSERTION_LABEL,
      address(contracts.poolProxy),
      0,
      abi.encodeWithSelector(
        contracts.poolProxy.flashLoanSimple.selector,
        address(mockFlashSimpleReceiver),
        asset,
        amount,
        emptyParams,
        0
      )
    );
  }

  // Test flashloan following Pool.FlashLoans.t.sol pattern
  function testFlashloan() public {
    // Transfer ownership of the token to the mock receiver
    vm.prank(poolAdmin);
    TestnetERC20(asset).transferOwnership(address(mockFlashSimpleReceiver));

    uint256 amount = 12e6;

    bytes memory emptyParams;

    // Execute flashloan
    vm.prank(alice);
    contracts.poolProxy.flashLoanSimple(
      address(mockFlashSimpleReceiver),
      asset,
      amount,
      emptyParams,
      0
    );
  }

  // Test that mimics the assertion's logic
  function testFlashloanFeeCalculation() public {
    // Transfer ownership of the token to the mock receiver
    vm.prank(poolAdmin);
    TestnetERC20(tokenList.usdx).transferOwnership(address(mockFlashSimpleReceiver));

    uint256 amount = 12e6;
    bytes memory emptyParams;

    // Calculate fee using the pool's premium rate
    uint256 fee = (amount * 5) / 10000; // 0.05% fee (5/10000 = 0.0005 = 0.05%)

    // Get aToken address
    address aTokenAddress = contracts.poolProxy.getReserveData(tokenList.usdx).aTokenAddress;
    uint256 preATokenBalance = usdx.balanceOf(aTokenAddress);

    uint256 totalRequired = preATokenBalance + fee;

    // Execute flashloan
    vm.prank(alice);
    contracts.poolProxy.flashLoanSimple(
      address(mockFlashSimpleReceiver),
      tokenList.usdx,
      amount,
      emptyParams,
      0
    );

    // Get final balances
    uint256 postATokenBalance = usdx.balanceOf(aTokenAddress);

    // Verify the balance increase matches our calculation
    require(
      postATokenBalance >= totalRequired,
      'Flashloan did not return enough funds to protocol'
    );
  }

  function testFlashloanSimple() public {
    // Transfer ownership of the token to the mock receiver
    vm.prank(poolAdmin);
    TestnetERC20(tokenList.usdx).transferOwnership(address(mockFlashSimpleReceiver));

    bytes memory emptyParams;

    // Execute flashloan
    vm.prank(alice);
    contracts.poolProxy.flashLoanSimple(
      address(mockFlashSimpleReceiver),
      tokenList.usdx,
      10e6,
      emptyParams,
      0
    );
  }
}
