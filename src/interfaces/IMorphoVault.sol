// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMorphoVault
 * @notice ERC4626-compliant interface for Morpho Vault V2 interactions
 * @dev Morpho Vault V2 is fully ERC4626 and ERC2612 compliant
 */
interface IMorphoVault {
    // ============ ERC4626 Core Functions ============

    /**
     * @notice Deposit assets into the vault
     * @param assets Amount of assets to deposit
     * @param receiver Address that will receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @notice Mint exact shares by depositing assets
     * @param shares Amount of shares to mint
     * @param receiver Address that will receive the shares
     * @return assets Amount of assets deposited
     */
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /**
     * @notice Withdraw assets from the vault
     * @param assets Amount of assets to withdraw
     * @param receiver Address that will receive the assets
     * @param owner Address of the share owner
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /**
     * @notice Redeem shares for assets
     * @param shares Amount of shares to redeem
     * @param receiver Address that will receive the assets
     * @param owner Address of the share owner
     * @return assets Amount of assets received
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // ============ ERC4626 View Functions ============

    /**
     * @notice Get the underlying asset address
     */
    function asset() external view returns (address);

    /**
     * @notice Get total assets under management
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Convert assets to shares
     */
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @notice Convert shares to assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /**
     * @notice Maximum deposit amount for a receiver
     */
    function maxDeposit(address receiver) external view returns (uint256);

    /**
     * @notice Preview deposit effects
     */
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /**
     * @notice Maximum mint amount for a receiver
     */
    function maxMint(address receiver) external view returns (uint256);

    /**
     * @notice Preview mint effects
     */
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /**
     * @notice Maximum withdraw amount for an owner
     */
    function maxWithdraw(address owner) external view returns (uint256);

    /**
     * @notice Preview withdraw effects
     */
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /**
     * @notice Maximum redeem amount for an owner
     */
    function maxRedeem(address owner) external view returns (uint256);

    /**
     * @notice Preview redeem effects
     */
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    // ============ ERC20 Functions (part of ERC4626) ============

    /**
     * @notice Get balance of shares for an account
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Get total supply of shares
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Approve spender to use shares
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @notice Transfer shares
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @notice Get allowance
     */
    function allowance(address owner, address spender) external view returns (uint256);
}
