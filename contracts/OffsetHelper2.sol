// SPDX-FileCopyrightText: 2022 Toucan Labs
//
// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "./OffsetHelperStorage.sol";
// ** Why `SafeERC20.sol`?
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ** How are we using interfaces instead of the actual contracts without ABIs?
import "./interfaces/IToucanContractRegistry.sol";
// ** Why do we need to instantiate a pool token in this contract?
import "./interfaces/IToucanPoolToken.sol";
import "./interfaces/IToucanCarbonOffsets.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import "hardhat/console.sol";

/**
 * @title Toucan Protocol Offset Helpers
 * @notice Helper functions that simplify the carbon offsetting (retirement)
 * process.
 *
 * Retiring carbon tokens requires multiple steps and interactions with
 * Toucan Protocol's main contracts:
 * 1. Obtain a Toucan pool token such as BCT or NCT (by performing a token
 *    swap).
 * 2. Redeem the pool token for a TCO2 token.
 * 3. Retire the TCO2 token.
 *
 * These steps are combined in each of the following "auto offset" methods
 * implemented in `OffsetHelper` to allow a retirement within one transaction:
 * - `autoOffsetPoolToken()` if the user already owns a Toucan pool
 *   token such as BCT or NCT,
 * - `autoOffsetExactOutETH()` if the user would like to perform a retirement
 *   using MATIC, specifying the exact amount of TCO2s to retire,
 * - `autoOffsetExactInETH()` if the user would like to perform a retirement
 *   using MATIC, swapping all sent MATIC into TCO2s,
 * - `autoOffsetExactOutToken()` if the user would like to perform a retirement
 *   using an ERC20 token (USDC, WETH or WMATIC), specifying the exact amount
 *   of TCO2s to retire,
 * - `autoOffsetExactInToken()` if the user would like to perform a retirement
 *   using an ERC20 token (USDC, WETH or WMATIC), specifying the exact amount
 *   of token to swap into TCO2s.
 *
 * In these methods, "auto" refers to the fact that these methods use
 * `autoRedeem()` in order to automatically choose a TCO2 token corresponding
 * to the oldest tokenized carbon project in the specfified token pool.
 * There are no fees incurred by the user when using `autoRedeem()`, i.e., the
 * user receives 1 TCO2 token for each pool token (BCT/NCT) redeemed.
 *
 * There are two `view` helper functions `calculateNeededETHAmount()` and
 * `calculateNeededTokenAmount()` that should be called before using
 * `autoOffsetExactOutETH()` and `autoOffsetExactOutToken()`, to determine how
 * much MATIC, respectively how much of the ERC20 token must be sent to the
 * `OffsetHelper` contract in order to retire the specified amount of carbon.
 *
 * The two `view` helper functions `calculateExpectedPoolTokenForETH()` and
 * `calculateExpectedPoolTokenForToken()` can be used to calculate the
 * expected amount of TCO2s that will be offset using functions
 * `autoOffsetExactInETH()` and `autoOffsetExactInToken()`.
 */
contract OffsetHelper is OffsetHelperStorage {
    using SafeERC20 for IERC20;

    /**
     * @notice Contract constructor. Should specify arrays of ERC20 symbols and
     * addresses that can used by the contract.
     *
     * @dev See `isEligible()` for a list of tokens that can be used in the
     * contract. These can be modified after deployment by the contract owner
     * using `setEligibleTokenAddress()` and `deleteEligibleTokenAddress()`.
     *
     * @param _eligibleTokenSymbols A list of token symbols.
     * @param _eligibleTokenAddresses A list of token addresses corresponding
     * to the provided token symbols.
     */
    constructor(
        string[] memory _eligibleTokenSymbols,
        address[] memory _eligibleTokenAddresses
    ) {
        uint256 i = 0;
        uint256 eligibleTokenSymbolsLen = _eligibleTokenSymbols.length;

        // Connecting _eligibleTokenSymbols with _eligibleTokenAddresses
        while (i < eligibleTokenSymbolsLen) {
            eligibleTokenAddresses[
                _eligibleTokenSymbols[i]
            ] = _eligibleTokenAddresses[i];
            i += 1;
        }
    }

    /**
     * @notice Emitted upon successful redemption of TCO2 tokens from a Toucan
     * pool token such as BCT or NCT.
     *
     * @param who The sender of the transaction
     * @param poolToken The address of the Toucan pool token used in the
     * redemption, for example, NCT or BCT
     * @param tco2s An array of the TCO2 addresses that were redeemed
     * @param amounts An array of the amounts of each TCO2 that were redeemed
     */
    event Redeemed(
        address who,
        address poolToken,
        address[] tco2s,
        uint256[] amounts
    );

    modifier onlyRedeemable(address _token) {
        require(isRedeemable(_token), "Token not redeemable");
        _;
    }

    modifier onlySwappable(address _token) {
        require(isSwappable(_token), "Token not swappable");
        _;
    }

    /* ------------------------------------------ */
    /* Offset Methods */
    /* ------------------------------------------ */

    // ** Offset Method 1 (specified BCT/NCT) ** //
    /**
     * @notice Retire carbon credits using the lowest quality (oldest) TCO2
     * tokens available by sending Toucan pool tokens, for example, BCT or NCT.
     *
     * This function:
     * 1. Redeems the pool token for the poorest quality TCO2 tokens available.
     * 2. Retires the TCO2 tokens.
     *
     * Note: The client must approve the pool token that is sent.
     *
     * @param _poolToken The address of the Toucan pool token that the
     * user wants to use, for example, NCT or BCT.
     * @param _amountToOffset The amount of TCO2 to offset.
     *
     * @return tco2s An array of the TCO2 addresses that were redeemed
     * @return amounts An array of the amounts of each TCO2 that were redeemed
     */
    function autoOffsetPoolToken(
        address _poolToken,
        uint256 _amountToOffset
    ) public returns (address[] memory tco2s, uint256[] memory amounts) {
        // deposit pool token from user to this contract
        deposit(_poolToken, _amountToOffset);

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, _amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // ** Offset Method 2 (specified BCT/NCT, swapped from MATIC) ** //
    /**
     * @notice Retire carbon credits using the lowest quality (oldest) TCO2
     * tokens available from the specified Toucan token pool by sending MATIC.
     * Use `calculateNeededETHAmount()` first in order to find out how much
     * MATIC is required to retire the specified quantity of TCO2.
     *
     * This function:
     * 1. Swaps the Matic sent to the contract for the specified pool token.
     * 2. Redeems the pool token for the poorest quality TCO2 tokens available.
     * 3. Retires the TCO2 tokens.
     *
     * @dev If the user sends (too) much MATIC, the leftover amount will be sent back
     * to the user.
     *
     * @param _poolToken The address of the Toucan pool token that the
     * user wants to use, for example, NCT or BCT.
     * @param _amountToOffset The amount of TCO2 to offset.
     *
     * @return tco2s An array of the TCO2 addresses that were redeemed
     * @return path
     * @return amounts An array of the amounts of each TCO2 that were redeemed
     */

    // custom multi-step path support (i.e. MATIC -> KLIMA -> BCT/NCT, etc.)
    function autoOffsetExactOutETH(
        address _poolToken,
        uint256 _amountToOffset,
        bool multiStepPath,
        address _intermediaryToken
    )
        public
        payable
        returns (
            address[] memory tco2s,
            address[] memory path,
            uint256[] memory amounts
        )
    {
        // swap MATIC for BCT / NCT
        (path, amounts) = swapExactOutETH(
            _poolToken,
            _amountToOffset,
            multiStepPath,
            _intermediaryToken
        );

        (
            // redeem BCT / NCT for TCO2s
            tco2s,
            amounts
        ) = autoRedeem(_poolToken, _amountToOffset);

        // test redeeming second TCO2 pool for NCT instead of first
        address[] memory tco2sNew = new address[](1);
        tco2sNew[0] = tco2s[1];
        uint256[] memory amountsNew = new uint256[](1);
        amountsNew[0] = amounts[1];

        // retire the TCO2s to achieve offset
        autoRetire(tco2sNew, amountsNew);
    }

    // pre-defined direct path support (i.e. MATIC -> BCT/NCT vs MATIC -> USDC -> BCT/NCT)
    function autoOffsetExactOutETH(
        address _poolToken,
        uint256 _amountToOffset,
        bool directPath
    )
        public
        payable
        returns (
            address[] memory tco2s,
            address[] memory path,
            uint256[] memory amounts
        )
    {
        // swap MATIC for BCT / NCT
        (path, amounts) = swapExactOutETH(
            _poolToken,
            _amountToOffset,
            directPath
        );

        (
            // redeem BCT / NCT for TCO2s
            tco2s,
            amounts
        ) = autoRedeem(_poolToken, _amountToOffset);

        // test redeeming second TCO2 pool for NCT instead of first
        address[] memory tco2sNew = new address[](1);
        tco2sNew[0] = tco2s[1];
        uint256[] memory amountsNew = new uint256[](1);
        amountsNew[0] = amounts[1];

        // retire the TCO2s to achieve offset
        autoRetire(tco2sNew, amountsNew);
    }

    // default
    function autoOffsetExactOutETH(
        address _poolToken,
        uint256 _amountToOffset
    )
        public
        payable
        returns (
            address[] memory tco2s,
            address[] memory path,
            uint256[] memory amounts
        )
    {
        // swap MATIC for BCT / NCT
        (path, amounts) = swapExactOutETH(_poolToken, _amountToOffset);

        (
            // redeem BCT / NCT for TCO2s
            tco2s,
            amounts
        ) = autoRedeem(_poolToken, _amountToOffset);

        // test redeeming second TCO2 pool for NCT instead of first
        address[] memory tco2sNew = new address[](1);
        tco2sNew[0] = tco2s[1];
        uint256[] memory amountsNew = new uint256[](1);
        amountsNew[0] = amounts[1];

        // retire the TCO2s to achieve offset
        autoRetire(tco2sNew, amountsNew);
    }

    // ** Offset Method 3 (specified MATIC) ** //
    /**
     * @notice Retire carbon credits using the lowest quality (oldest) TCO2
     * tokens available from the specified Toucan token pool by sending MATIC.
     * All provided MATIC is consumed for offsetting.
     *
     * This function:
     * 1. Swaps the Matic sent to the contract for the specified pool token.
     * 2. Redeems the pool token for the poorest quality TCO2 tokens available.
     * 3. Retires the TCO2 tokens.
     *
     * @param _poolToken The address of the Toucan pool token that the
     * user wants to use, for example, NCT or BCT.
     *
     * @return tco2s An array of the TCO2 addresses that were redeemed
     * @return amounts An array of the amounts of each TCO2 that were redeemed
     */
    // custom multi-step path support (i.e. MATIC -> KLIMA -> BCT/NCT, etc.)
    function autoOffsetExactInETH(
        address _poolToken,
        bool multiStepPath,
        address _intermediaryToken
    )
        public
        payable
        returns (address[] memory tco2s, uint256[] memory amounts)
    {
        // swap MATIC for BCT / NCT
        uint256 amountToOffset = swapExactInETH(
            _poolToken,
            multiStepPath,
            _intermediaryToken
        );

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // pre-defined direct path support (i.e. MATIC -> BCT/NCT vs MATIC -> USDC -> BCT/NCT)
    function autoOffsetExactInETH(
        address _poolToken,
        bool directPath
    )
        public
        payable
        returns (address[] memory tco2s, uint256[] memory amounts)
    {
        // swap MATIC for BCT / NCT
        uint256 amountToOffset = swapExactInETH(_poolToken, directPath);

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // custom multi-step path support
    function autoOffsetExactInETH(
        address _poolToken
    )
        public
        payable
        returns (address[] memory tco2s, uint256[] memory amounts)
    {
        // swap MATIC for BCT / NCT
        uint256 amountToOffset = swapExactInETH(_poolToken);

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // ** Offset Method 4 (specified BCT/NCT, swapped from WMATIC/USDC/WETH) ** //
    /**
     * @notice Retire carbon credits using the lowest quality (oldest) TCO2
     * tokens available from the specified Toucan token pool by sending ERC20
     * tokens (USDC, WETH, WMATIC). Use `calculateNeededTokenAmount` first in
     * order to find out how much of the ERC20 token is required to retire the
     * specified quantity of TCO2.
     *
     * This function:
     * 1. Swaps the ERC20 token sent to the contract for the specified pool token.
     * 2. Redeems the pool token for the poorest quality TCO2 tokens available.
     * 3. Retires the TCO2 tokens.
     *
     * Note: The client must approve the ERC20 token that is sent to the contract.
     *
     * @dev When automatically redeeming pool tokens for the lowest quality
     * TCO2s there are no fees and you receive exactly 1 TCO2 token for 1 pool
     * token.
     *
     * @param _depositedToken The address of the ERC20 token that the user sends
     * (must be one of USDC, WETH, WMATIC)
     * @param _poolToken The address of the Toucan pool token that the
     * user wants to use, for example, NCT or BCT
     * @param _amountToOffset The amount of TCO2 to offset
     *
     * @return tco2s An array of the TCO2 addresses that were redeemed
     * @return amounts An array of the amounts of each TCO2 that were redeemed
     */
    // custom multi-step path support (i.e. WETH -> KLIMA -> BCT/NCT, etc.)
    function autoOffsetExactOutToken(
        address _depositedToken,
        address _poolToken,
        uint256 _amountToOffset,
        bool multiStepPath,
        address _intermediaryToken
    ) public returns (address[] memory tco2s, uint256[] memory amounts) {
        // swap input token for BCT / NCT
        swapExactOutToken(
            _depositedToken,
            _poolToken,
            _amountToOffset,
            multiStepPath,
            _intermediaryToken
        );

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, _amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // pre-defined/custom direct path support (i.e. WETH -> BCT/NCT vs WETH -> USDC -> BCT/NCT)
    function autoOffsetExactOutToken(
        address _depositedToken,
        address _poolToken,
        uint256 _amountToOffset,
        bool directPath
    ) public returns (address[] memory tco2s, uint256[] memory amounts) {
        // swap input token for BCT / NCT
        swapExactOutToken(
            _depositedToken,
            _poolToken,
            _amountToOffset,
            directPath
        );

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, _amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // default
    function autoOffsetExactOutToken(
        address _depositedToken,
        address _poolToken,
        uint256 _amountToOffset
    ) public returns (address[] memory tco2s, uint256[] memory amounts) {
        // swap input token for BCT / NCT
        swapExactOutToken(_depositedToken, _poolToken, _amountToOffset);

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, _amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // ** Offset Method 5 (specified WMATIC/USDC/WETH) ** //
    /**
     * @notice Retire carbon credits using the lowest quality (oldest) TCO2
     * tokens available from the specified Toucan token pool by sending ERC20
     * tokens (USDC, WETH, WMATIC). All provided token is consumed for
     * offsetting.
     *
     * This function:
     * 1. Swaps the ERC20 token sent to the contract for the specified pool token.
     * 2. Redeems the pool token for the poorest quality TCO2 tokens available.
     * 3. Retires the TCO2 tokens.
     *
     * Note: The client must approve the ERC20 token that is sent to the contract.
     *
     * @dev When automatically redeeming pool tokens for the lowest quality
     * TCO2s there are no fees and you receive exactly 1 TCO2 token for 1 pool
     * token.
     *
     * @param _fromToken The address of the ERC20 token that the user sends
     * (must be one of USDC, WETH, WMATIC)
     * @param _amountToSwap The amount of ERC20 token to swap into Toucan pool
     * token. Full amount will be used for offsetting.
     * @param _poolToken The address of the Toucan pool token that the
     * user wants to use, for example, NCT or BCT
     *
     * @return tco2s An array of the TCO2 addresses that were redeemed
     * @return amounts An array of the amounts of each TCO2 that were redeemed
     */
    // custom multi-step path support (i.e. WETH -> KLIMA -> BCT/NCT, etc.)
    function autoOffsetExactInToken(
        address _fromToken,
        uint256 _amountToSwap,
        address _poolToken,
        bool multiStepPath,
        address _intermediaryToken
    ) public returns (address[] memory tco2s, uint256[] memory amounts) {
        // swap input token for BCT / NCT
        uint256 amountToOffset = swapExactInToken(
            _fromToken,
            _amountToSwap,
            _poolToken,
            multiStepPath,
            _intermediaryToken
        );

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // pre-defined/custom direct path support (i.e. WETH -> BCT/NCT vs WETH -> USDC -> BCT/NCT)
    function autoOffsetExactInToken(
        address _fromToken,
        uint256 _amountToSwap,
        address _poolToken,
        bool directPath
    ) public returns (address[] memory tco2s, uint256[] memory amounts) {
        // swap input token for BCT / NCT
        uint256 amountToOffset = swapExactInToken(
            _fromToken,
            _amountToSwap,
            _poolToken,
            directPath
        );

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    // default
    function autoOffsetExactInToken(
        address _fromToken,
        uint256 _amountToSwap,
        address _poolToken
    ) public returns (address[] memory tco2s, uint256[] memory amounts) {
        // swap input token for BCT / NCT
        uint256 amountToOffset = swapExactInToken(
            _fromToken,
            _amountToSwap,
            _poolToken
        );

        // redeem BCT / NCT for TCO2s
        (tco2s, amounts) = autoRedeem(_poolToken, amountToOffset);

        // retire the TCO2s to achieve offset
        autoRetire(tco2s, amounts);
    }

    /* ------------------------------------------ */
    /* Used Helper Functions */
    /* ------------------------------------------ */

    /**
     * @notice Allow users to deposit BCT / NCT.
     * @dev Needs to be approved
     */
    function deposit(
        address _erc20Addr,
        uint256 _amount
    ) public onlyRedeemable(_erc20Addr) {
        // * Checks-Effects-Interactions change
        // Although here it seems to not be a security issue since no
        // user in their right mind do a re-entrancy attack as it would
        // drain their own balances without being reflected in the contract
        balances[msg.sender][_erc20Addr] += _amount;
        // ** Can I also use .transferFrom/.safeTransferFrom without needing to approve the txs?
        // ** They're probably already approved by the user from the UI.
        IERC20(_erc20Addr).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Redeems the specified amount of NCT / BCT for TCO2.
     * @dev Needs to be approved on the client side
     * @param _fromToken Could be the address of NCT or BCT
     * @param _amount Amount to redeem
     * @return tco2s An array of the TCO2 addresses that were redeemed
     * @return amounts An array of the amounts of each TCO2 that were redeemed
     */
    // ** Why `public`? Isn't `autoRedeem` only callable within other public
    // ** functions and hence have no reason to be public?
    function autoRedeem(
        address _fromToken,
        uint256 _amount
    )
        public
        onlyRedeemable(_fromToken)
        returns (address[] memory tco2s, uint256[] memory amounts)
    {
        require(
            balances[msg.sender][_fromToken] >= _amount,
            "Insufficient NCT/BCT balance"
        );

        // instantiate pool token (NCT or BCT)
        IToucanPoolToken PoolTokenImplementation = IToucanPoolToken(_fromToken);

        // auto redeem pool token for TCO2; will transfer
        // automatically picked TCO2 to this contract
        (tco2s, amounts) = PoolTokenImplementation.redeemAuto2(_amount);

        // update balances
        balances[msg.sender][_fromToken] -= _amount;
        uint256 tco2sLen = tco2s.length;
        for (uint256 i = 0; i < tco2sLen; i++) {
            balances[msg.sender][tco2s[i]] += amounts[i];
        }

        emit Redeemed(msg.sender, _fromToken, tco2s, amounts);
    }

    /**
     * @notice Retire the specified TCO2 tokens.
     * @param _tco2s The addresses of the TCO2s to retire
     * @param _amounts The amounts to retire from each of the corresponding
     * TCO2 addresses
     */
    // ** Why `public`? Isn't `autoRetire` only callable within other public
    // ** functions and hence have no reason to be public?
    function autoRetire(
        address[] memory _tco2s,
        uint256[] memory _amounts
    ) public {
        uint256 tco2sLen = _tco2s.length;
        require(tco2sLen != 0, "Array empty");
        require(tco2sLen == _amounts.length, "Arrays unequal");

        uint256 i = 0;
        while (i < tco2sLen) {
            require(
                balances[msg.sender][_tco2s[i]] >= _amounts[i],
                "Insufficient TCO2 balance"
            );

            balances[msg.sender][_tco2s[i]] -= _amounts[i];

            IToucanCarbonOffsets(_tco2s[i]).retire(_amounts[i]);

            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Swap MATIC for Toucan pool tokens (BCT/NCT) on SushiSwap.
     * Remaining MATIC that was not consumed by the swap is returned.
     * @param _toToken Token to swap for (will be held within contract)
     * @param _toAmount Amount of NCT / BCT wanted
     */
    // custom multi-step path support
    function swapExactOutETH(
        address _toToken,
        uint256 _toAmount,
        bool multiStepPath,
        address _intermediaryToken
    )
        public
        payable
        onlyRedeemable(_toToken)
        returns (address[] memory path, uint256[] memory amounts)
    {
        // calculate path & amounts
        // ** Why are we using WMATIC token when we're supposed to be using MATIC?
        address fromToken = eligibleTokenAddresses["WMATIC"];

        // custom multi step path
        path = generatePath(
            fromToken,
            _toToken,
            multiStepPath,
            _intermediaryToken
        );

        // swap
        // ** `swapETHForExactTokens()` requires first address in the path to be WETH but we use MATIC here
        // ** How does this work? I guess WMATIC = WETH in this case.

        // ** Don't I need to approve the transfer of my MATIC first?
        amounts = routerSushi().swapETHForExactTokens{value: msg.value}(
            _toAmount,
            path,
            address(this),
            block.timestamp
        );

        // send surplus back
        if (msg.value > amounts[0]) {
            uint256 leftoverETH = msg.value - amounts[0];
            // ** What does `new bytes(0)` mean?
            (bool success, ) = msg.sender.call{value: leftoverETH}(
                new bytes(0)
            );

            require(success, "Failed to send surplus back");
        }

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += _toAmount;
    }

    // pre-defined/custom direct path support
    function swapExactOutETH(
        address _toToken,
        uint256 _toAmount,
        bool directPath
    )
        public
        payable
        onlyRedeemable(_toToken)
        returns (address[] memory path, uint256[] memory amounts)
    {
        // calculate path & amounts
        // ** Why are we using WMATIC token when we're supposed to be using MATIC?
        address fromToken = eligibleTokenAddresses["WMATIC"];

        path = generatePath(fromToken, _toToken, directPath);

        // swap
        // ** `swapETHForExactTokens()` requires first address in the path to be WETH but we use MATIC here
        // ** How does this work? I guess WMATIC = WETH in this case.

        // ** Don't I need to approve the transfer of my MATIC first?
        amounts = routerSushi().swapETHForExactTokens{value: msg.value}(
            _toAmount,
            path,
            address(this),
            block.timestamp
        );

        // send surplus back
        if (msg.value > amounts[0]) {
            uint256 leftoverETH = msg.value - amounts[0];
            // ** What does `new bytes(0)` mean?
            (bool success, ) = msg.sender.call{value: leftoverETH}(
                new bytes(0)
            );

            require(success, "Failed to send surplus back");
        }

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += _toAmount;
    }

    // default
    function swapExactOutETH(
        address _toToken,
        uint256 _toAmount
    )
        public
        payable
        onlyRedeemable(_toToken)
        returns (address[] memory path, uint256[] memory amounts)
    {
        // calculate path & amounts
        // ** Why are we using WMATIC token when we're supposed to be using MATIC?
        address fromToken = eligibleTokenAddresses["WMATIC"];

        path = generatePath(fromToken, _toToken);

        // swap
        // ** `swapETHForExactTokens()` requires first address in the path to be WETH but we use MATIC here
        // ** How does this work? I guess WMATIC = WETH in this case.

        // ** Don't I need to approve the transfer of my MATIC first?
        amounts = routerSushi().swapETHForExactTokens{value: msg.value}(
            _toAmount,
            path,
            address(this),
            block.timestamp
        );

        // send surplus back
        if (msg.value > amounts[0]) {
            uint256 leftoverETH = msg.value - amounts[0];
            // ** What does `new bytes(0)` mean?
            (bool success, ) = msg.sender.call{value: leftoverETH}(
                new bytes(0)
            );

            require(success, "Failed to send surplus back");
        }

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += _toAmount;
    }

    // custom multi-step path support
    function swapExactInETH(
        address _toToken,
        bool multiStepPath,
        address _intermediaryToken
    ) public payable onlyRedeemable(_toToken) returns (uint256) {
        // calculate path & amounts
        address fromToken = eligibleTokenAddresses["WMATIC"];
        address[] memory path = generatePath(
            fromToken,
            _toToken,
            multiStepPath,
            _intermediaryToken
        );

        // swap
        // ** Does MATIC get auto-wrapped into WMATIC here?
        uint256[] memory amounts = routerSushi().swapExactETHForTokens{
            value: msg.value
        }(0, path, address(this), block.timestamp);

        // ** I guess I could also add a sanity check here:
        // ** require(path.length == amounts.length, "Unequal arrays");
        uint256 amountOut = amounts[path.length - 1];

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += amountOut;

        return amountOut;
    }

    // pre-defined/custom direct path support
    function swapExactInETH(
        address _toToken,
        bool directPath
    ) public payable onlyRedeemable(_toToken) returns (uint256) {
        // calculate path & amounts
        address fromToken = eligibleTokenAddresses["WMATIC"];
        address[] memory path = generatePath(fromToken, _toToken, directPath);

        // swap
        // ** Does MATIC get auto-wrapped into WMATIC here?
        uint256[] memory amounts = routerSushi().swapExactETHForTokens{
            value: msg.value
        }(0, path, address(this), block.timestamp);

        // ** I guess I could also add a sanity check here:
        // ** require(path.length == amounts.length, "Unequal arrays");
        uint256 amountOut = amounts[path.length - 1];

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += amountOut;

        return amountOut;
    }

    // default
    function swapExactInETH(
        address _toToken
    ) public payable onlyRedeemable(_toToken) returns (uint256) {
        // calculate path & amounts
        address fromToken = eligibleTokenAddresses["WMATIC"];
        address[] memory path = generatePath(fromToken, _toToken);

        // swap
        // ** Does MATIC get auto-wrapped into WMATIC here?
        uint256[] memory amounts = routerSushi().swapExactETHForTokens{
            value: msg.value
        }(0, path, address(this), block.timestamp);

        // ** I guess I could also add a sanity check here:
        // ** require(path.length == amounts.length, "Unequal arrays");
        uint256 amountOut = amounts[path.length - 1];

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += amountOut;

        return amountOut;
    }

    /**
     * @notice Swap eligible ERC20 tokens for Toucan pool tokens (BCT/NCT) on SushiSwap
     * @dev Needs to be approved on the client side
     * @param _fromToken The ERC20 oken to deposit and swap
     * @param _toToken The token to swap for (will be held within contract)
     * @param _toAmount The required amount of the Toucan pool token (NCT/BCT)
     */
    // custom multi-step path support
    function swapExactOutToken(
        address _fromToken,
        address _toToken,
        uint256 _toAmount,
        bool multiStepPath,
        address _intermediaryToken
    ) public onlySwappable(_fromToken) onlyRedeemable(_toToken) {
        // calculate path & amounts
        // ** Could we replace `memory` with `calldata`?
        (
            address[] memory path,
            uint256[] memory expAmounts
        ) = calculateExactOutSwap(
                _fromToken,
                _toToken,
                _toAmount,
                multiStepPath,
                _intermediaryToken
            );
        uint256 amountIn = expAmounts[0];

        // transfer tokens
        IERC20(_fromToken).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        // approve router
        // ** 1. Does OH contract (not user) have approve the router contract?
        // ** 2. If so, does OH contract approve it automatically? It seems so.
        IERC20(_fromToken).approve(sushiRouterAddress, amountIn);

        // swap
        uint256[] memory amounts = routerSushi().swapTokensForExactTokens(
            _toAmount,
            amountIn,
            path,
            address(this),
            block.timestamp
        );

        // remove remaining approval if less input token was consumed
        if (amounts[0] < amountIn) {
            IERC20(_fromToken).approve(sushiRouterAddress, 0);
        }

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += _toAmount;
    }

    // pre-defined/custom direct path support
    function swapExactOutToken(
        address _fromToken,
        address _toToken,
        uint256 _toAmount,
        bool directPath
    ) public onlySwappable(_fromToken) onlyRedeemable(_toToken) {
        // calculate path & amounts
        // ** Could we replace `memory` with `calldata`?
        (
            address[] memory path,
            uint256[] memory expAmounts
        ) = calculateExactOutSwap(_fromToken, _toToken, _toAmount, directPath);
        uint256 amountIn = expAmounts[0];

        // transfer tokens
        IERC20(_fromToken).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        // approve router
        // ** 1. Does OH contract (not user) have approve the router contract?
        // ** 2. If so, does OH contract approve it automatically? It seems so.
        IERC20(_fromToken).approve(sushiRouterAddress, amountIn);

        // swap
        uint256[] memory amounts = routerSushi().swapTokensForExactTokens(
            _toAmount,
            amountIn,
            path,
            address(this),
            block.timestamp
        );

        // remove remaining approval if less input token was consumed
        if (amounts[0] < amountIn) {
            IERC20(_fromToken).approve(sushiRouterAddress, 0);
        }

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += _toAmount;
    }

    // default
    function swapExactOutToken(
        address _fromToken,
        address _toToken,
        uint256 _toAmount
    ) public onlySwappable(_fromToken) onlyRedeemable(_toToken) {
        // calculate path & amounts
        // ** Could we replace `memory` with `calldata`?
        (
            address[] memory path,
            uint256[] memory expAmounts
        ) = calculateExactOutSwap(_fromToken, _toToken, _toAmount);
        uint256 amountIn = expAmounts[0];

        // transfer tokens
        IERC20(_fromToken).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        // approve router
        // ** 1. Does OH contract (not user) have approve the router contract?
        // ** 2. If so, does OH contract approve it automatically? It seems so.
        IERC20(_fromToken).approve(sushiRouterAddress, amountIn);

        // swap
        uint256[] memory amounts = routerSushi().swapTokensForExactTokens(
            _toAmount,
            amountIn,
            path,
            address(this),
            block.timestamp
        );

        // remove remaining approval if less input token was consumed
        if (amounts[0] < amountIn) {
            IERC20(_fromToken).approve(sushiRouterAddress, 0);
        }

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += _toAmount;
    }

    // ** Why `public`?
    // I'd change `_fromAmount` & `_toToken` names for consistency
    // E.g. `_fromAmount` -> `_amountToSwap` & `_toToken` -> `_poolToken`
    // custom multi-step path support
    function swapExactInToken(
        address _fromToken,
        uint256 _fromAmount,
        address _toToken,
        bool multiStepPath,
        address _intermediaryToken
    )
        public
        onlySwappable(_fromToken)
        onlyRedeemable(_toToken)
        returns (uint256)
    {
        // calculate path & amounts
        address[] memory path = generatePath(
            _fromToken,
            _toToken,
            multiStepPath,
            _intermediaryToken
        );
        uint256 len = path.length;

        // transfer tokens
        IERC20(_fromToken).safeTransferFrom(
            msg.sender,
            address(this),
            _fromAmount
        );

        // approve router
        // ** Why are we using `safeApprove` here if we used `approve` in `swapExactOutToken`?
        IERC20(_fromToken).safeApprove(sushiRouterAddress, _fromAmount);

        // swap
        uint256[] memory amounts = routerSushi().swapExactTokensForTokens(
            _fromAmount,
            // ** Why 0?
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 amountOut = amounts[len - 1];

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += amountOut;

        return amountOut;
    }

    // pre-defined/custom direct path support
    function swapExactInToken(
        address _fromToken,
        uint256 _fromAmount,
        address _toToken,
        bool directPath
    )
        public
        onlySwappable(_fromToken)
        onlyRedeemable(_toToken)
        returns (uint256)
    {
        // calculate path & amounts
        address[] memory path = generatePath(_fromToken, _toToken, directPath);
        uint256 len = path.length;

        // transfer tokens
        IERC20(_fromToken).safeTransferFrom(
            msg.sender,
            address(this),
            _fromAmount
        );

        // approve router
        // ** Why are we using `safeApprove` here if we used `approve` in `swapExactOutToken`?
        IERC20(_fromToken).safeApprove(sushiRouterAddress, _fromAmount);

        // swap
        uint256[] memory amounts = routerSushi().swapExactTokensForTokens(
            _fromAmount,
            // ** Why 0?
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 amountOut = amounts[len - 1];

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += amountOut;

        return amountOut;
    }

    // default
    function swapExactInToken(
        address _fromToken,
        uint256 _fromAmount,
        address _toToken
    )
        public
        onlySwappable(_fromToken)
        onlyRedeemable(_toToken)
        returns (uint256)
    {
        // calculate path & amounts
        address[] memory path = generatePath(_fromToken, _toToken);
        uint256 len = path.length;

        // transfer tokens
        IERC20(_fromToken).safeTransferFrom(
            msg.sender,
            address(this),
            _fromAmount
        );

        // approve router
        // ** Why are we using `safeApprove` here if we used `approve` in `swapExactOutToken`?
        IERC20(_fromToken).safeApprove(sushiRouterAddress, _fromAmount);

        // swap
        uint256[] memory amounts = routerSushi().swapExactTokensForTokens(
            _fromAmount,
            // ** Why 0?
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 amountOut = amounts[len - 1];

        // ** Adding Checks-Effects-Interactions pattern here doesn't make sense to me
        // ** The user should send funds first before their contract balance is updated
        // update balances
        balances[msg.sender][_toToken] += amountOut;

        return amountOut;
    }

    // custom multi-step path support
    function generatePath(
        address _fromToken,
        address _toToken,
        bool multiStepPath,
        address _intermediaryToken
    ) internal view returns (address[] memory) {
        console.log("custom multi-step generatePath ran");
        address[] memory path = new address[](3);
        path[0] = _fromToken;
        path[1] = _intermediaryToken;
        path[2] = _toToken;
        return path;
    }

    // custom/pre-defined direct path support
    function generatePath(
        address _fromToken,
        address _toToken,
        bool directPath
    ) internal view returns (address[] memory) {
        console.log("pre-defined/custom direct generatePath ran");
        address[] memory path = new address[](2);
        path[0] = _fromToken;
        path[1] = _toToken;
        return path;
    }

    // ** Why not `private`?
    // default
    function generatePath(
        address _fromToken,
        address _toToken
    ) internal view returns (address[] memory) {
        console.log("default generatePath ran");
        if (_fromToken == eligibleTokenAddresses["USDC"]) {
            address[] memory path = new address[](2);
            path[0] = _fromToken;
            path[1] = _toToken;
            return path;
        } else {
            address[] memory path = new address[](3);
            path[0] = _fromToken;
            path[1] = eligibleTokenAddresses["USDC"];
            path[2] = _toToken;
            return path;
        }
    }

    // ** Why not `private`?
    function routerSushi() internal view returns (IUniswapV2Router02) {
        // ** Don't understand the significance of this line
        return IUniswapV2Router02(sushiRouterAddress);
    }

    // ** Why not `private`?
    // custom multi-step path support
    function calculateExactOutSwap(
        address _fromToken,
        address _toToken,
        uint256 _toAmount,
        bool multiStepPath,
        address _intermediaryToken
    ) internal view returns (address[] memory path, uint256[] memory amounts) {
        path = generatePath(
            _fromToken,
            _toToken,
            multiStepPath,
            _intermediaryToken
        );
        uint256 len = path.length;

        // ** What does `getAmountsIn()` do exactly?
        amounts = routerSushi().getAmountsIn(_toAmount, path);

        // sanity check arrays
        require(len == amounts.length, "Arrays unequal");
        require(_toAmount == amounts[len - 1], "Output amount mismatch");
    }

    // custom/pre-defined direct path support
    function calculateExactOutSwap(
        address _fromToken,
        address _toToken,
        uint256 _toAmount,
        bool directPath
    ) internal view returns (address[] memory path, uint256[] memory amounts) {
        path = generatePath(_fromToken, _toToken, directPath);
        uint256 len = path.length;

        // ** What does `getAmountsIn()` do exactly?
        amounts = routerSushi().getAmountsIn(_toAmount, path);

        // sanity check arrays
        require(len == amounts.length, "Arrays unequal");
        require(_toAmount == amounts[len - 1], "Output amount mismatch");
    }

    // default
    function calculateExactOutSwap(
        address _fromToken,
        address _toToken,
        uint256 _toAmount
    ) internal view returns (address[] memory path, uint256[] memory amounts) {
        path = generatePath(_fromToken, _toToken);
        uint256 len = path.length;

        // ** What does `getAmountsIn()` do exactly?
        amounts = routerSushi().getAmountsIn(_toAmount, path);

        // sanity check arrays
        require(len == amounts.length, "Arrays unequal");
        require(_toAmount == amounts[len - 1], "Output amount mismatch");
    }

    /* ------------------------------------------ */
    /* Used Helper Functions */
    /* ------------------------------------------ */

    /**
     * @notice Return how much of the specified ERC20 token is required in
     * order to swap for the desired amount of a Toucan pool token, for
     * example, BCT or NCT.
     *
     * @param _fromToken The address of the ERC20 token used for the swap
     * @param _toToken The address of the pool token to swap for,
     * for example, NCT or BCT
     * @param _toAmount The desired amount of pool token to receive
     * @return amountsIn The amount of the ERC20 token required in order to
     * swap for the specified amount of the pool token
     */
    function calculateNeededTokenAmount(
        address _fromToken,
        address _toToken,
        uint256 _toAmount
    )
        public
        view
        onlySwappable(_fromToken)
        onlyRedeemable(_toToken)
        returns (uint256)
    {
        (, uint256[] memory amounts) = calculateExactOutSwap(
            _fromToken,
            _toToken,
            _toAmount
        );
        return amounts[0];
    }

    /**
     * @notice Return how much MATIC is required in order to swap for the
     * desired amount of a Toucan pool token, for example, BCT or NCT.
     *
     * @param _toToken The address of the pool token to swap for, for
     * example, NCT or BCT
     * @param _toAmount The desired amount of pool token to receive
     * @return amounts The amount of MATIC required in order to swap for
     * the specified amount of the pool token
     */
    function calculateNeededETHAmount(
        address _toToken,
        uint256 _toAmount
    ) public view onlyRedeemable(_toToken) returns (uint256) {
        address fromToken = eligibleTokenAddresses["WMATIC"];
        (, uint256[] memory amounts) = calculateExactOutSwap(
            fromToken,
            _toToken,
            _toAmount
        );
        return amounts[0];
    }

    /**
     * @notice Calculates the expected amount of Toucan Pool token that can be
     * acquired by swapping the provided amount of ERC20 token.
     *
     * @param _fromToken The address of the ERC20 token used for the swap
     * @param _fromAmount The amount of ERC20 token to swap
     * @param _toToken The address of the pool token to swap for,
     * for example, NCT or BCT
     * @return The expected amount of Pool token that can be acquired
     */
    function calculateExpectedPoolTokenForToken(
        address _fromToken,
        uint256 _fromAmount,
        address _toToken
    )
        public
        view
        onlySwappable(_fromToken)
        onlyRedeemable(_toToken)
        returns (uint256)
    {
        (, uint256[] memory amounts) = calculateExactInSwap(
            _fromToken,
            _fromAmount,
            _toToken
        );
        return amounts[amounts.length - 1];
    }

    /**
     * @notice Calculates the expected amount of Toucan Pool token that can be
     * acquired by swapping the provided amount of MATIC.
     *
     * @param _fromMaticAmount The amount of MATIC to swap
     * @param _toToken The address of the pool token to swap for,
     * for example, NCT or BCT
     * @return The expected amount of Pool token that can be acquired
     */
    function calculateExpectedPoolTokenForETH(
        uint256 _fromMaticAmount,
        address _toToken
    ) public view onlyRedeemable(_toToken) returns (uint256) {
        address fromToken = eligibleTokenAddresses["WMATIC"];
        (, uint256[] memory amounts) = calculateExactInSwap(
            fromToken,
            _fromMaticAmount,
            _toToken
        );
        return amounts[amounts.length - 1];
    }

    /* calculateExpectedPoolTokenForToken() & calculateExpectedPoolTokenForETH() helper */
    function calculateExactInSwap(
        address _fromToken,
        uint256 _fromAmount,
        address _toToken
    ) internal view returns (address[] memory path, uint256[] memory amounts) {
        path = generatePath(_fromToken, _toToken);

        amounts = routerSushi().getAmountsOut(_fromAmount, path);

        // sanity check arrays
        require(path.length == amounts.length, "Arrays unequal");
        require(_fromAmount == amounts[0], "Input amount mismatch");
    }

    /**
     * @notice Allow users to withdraw tokens they have deposited.
     */
    function withdraw(address _erc20Addr, uint256 _amount) public {
        require(
            balances[msg.sender][_erc20Addr] >= _amount,
            "Insufficient balance"
        );

        // * Checks-Effects-Interactions change
        balances[msg.sender][_erc20Addr] -= _amount;
        IERC20(_erc20Addr).safeTransfer(msg.sender, _amount);
    }

    /* ------------------------------------------ */
    /* Admin Functions */
    /* ------------------------------------------ */

    /**
     * @notice Change or add eligible tokens and their addresses.
     * @param _tokenSymbol The symbol of the token to add
     * @param _address The address of the token to add
     */
    function setEligibleTokenAddress(
        string memory _tokenSymbol,
        address _address
    ) public virtual onlyOwner {
        eligibleTokenAddresses[_tokenSymbol] = _address;
    }

    /**
     * @notice Delete eligible tokens stored in the contract.
     * @param _tokenSymbol The symbol of the token to remove
     */
    function deleteEligibleTokenAddress(
        string memory _tokenSymbol
    ) public virtual onlyOwner {
        delete eligibleTokenAddresses[_tokenSymbol];
    }

    /**
     * @notice Change the TCO2 contracts registry.
     * @param _address The address of the Toucan contract registry to use
     */
    // ** Why `public`?
    function setToucanContractRegistry(
        address _address
    ) public virtual onlyOwner {
        contractRegistryAddress = _address;
    }

    /* ------------------------------------------ */
    /* Modifier/Misc Functions */
    /* ------------------------------------------ */

    /**
     * @notice Checks whether an address is a Toucan pool token address
     * @param _erc20Address address of token to be checked
     * @return True if the address is a Toucan pool token address
     */
    function isRedeemable(address _erc20Address) private view returns (bool) {
        if (_erc20Address == eligibleTokenAddresses["BCT"]) return true;
        if (_erc20Address == eligibleTokenAddresses["NCT"]) return true;
        return false;
    }

    /**
     * @notice Checks whether an address can be used in a token swap
     * @param _erc20Address address of token to be checked
     * @return True if the specified address can be used in a swap
     */
    function isSwappable(address _erc20Address) private view returns (bool) {
        if (_erc20Address == eligibleTokenAddresses["USDC"]) return true;
        if (_erc20Address == eligibleTokenAddresses["WETH"]) return true;
        if (_erc20Address == eligibleTokenAddresses["WMATIC"]) return true;
        return false;
    }

    /**
     * @notice Checks whether an address can be used by the contract.
     * @param _erc20Address address of the ERC20 token to be checked
     * @return True if the address can be used by the contract
     */
    // ** Seems like `isEligible()` isn't used anywhere in this contract
    function isEligible(address _erc20Address) private view returns (bool) {
        bool isToucanContract = IToucanContractRegistry(contractRegistryAddress)
            .checkERC20(_erc20Address);
        if (isToucanContract) return true;
        if (_erc20Address == eligibleTokenAddresses["BCT"]) return true;
        if (_erc20Address == eligibleTokenAddresses["NCT"]) return true;
        if (_erc20Address == eligibleTokenAddresses["USDC"]) return true;
        if (_erc20Address == eligibleTokenAddresses["WETH"]) return true;
        if (_erc20Address == eligibleTokenAddresses["WMATIC"]) return true;
        return false;
    }

    receive() external payable {}

    fallback() external payable {}
}
