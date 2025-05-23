// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import './MarketInput.sol';

contract PhylaxTestnetMarketInput is MarketInput {
  function _getMarketInput(
    address deployer
  )
    internal
    pure
    override
    returns (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory deployedContracts
    )
  {
    roles.marketOwner = deployer;
    roles.emergencyAdmin = deployer;
    roles.poolAdmin = deployer;

    config.marketId = 'Aave V3 PhylaxTestnet Market';
    config.providerId = 808080;
    config.oracleDecimals = 8;
    config.flashLoanPremiumTotal = 0.0005e4;
    config.flashLoanPremiumToProtocol = 0.0004e4;
    config.networkBaseTokenPriceInUsdProxyAggregator = 0xC5cC91BEC567D0dFBA659894399a530b9e606128; // mock aggregator
    config
      .marketReferenceCurrencyPriceInUsdProxyAggregator = 0xC5cC91BEC567D0dFBA659894399a530b9e606128; // mock aggregator
    config.wrappedNativeToken = 0x7580b73B8cd5E3c30ccD76b4cE1038c693958564; // WETH9 address

    return (roles, config, flags, deployedContracts);
  }
}
