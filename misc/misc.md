    // custom multi-step path support
    function autoOffsetExactOutETH(
        address _poolToken,
        uint256 _amountToOffset,
        bool customPath,
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
            customPath,
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

    // custom direct path support
    function autoOffsetExactOutETH(
        address _poolToken,
        uint256 _amountToOffset,
        bool customPath
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
            customPath
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

---

    // custom multi-step path support
    function swapExactOutETH(
        address _toToken,
        uint256 _toAmount,
        bool customPath,
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

        if (customPath) {
            if (multiStepPath) {
                // custom multi step path
                path = generatePath(
                    fromToken,
                    _intermediaryToken,
                    _toToken,
                    customPath
                );
            } else {
                // custom direct path
                path = generatePath(fromToken, _toToken, customPath);
            }
        } else {
            // business as usual
            path = generatePath(fromToken, _toToken);
        }

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

    // custom direct path support
    function swapExactOutETH(
        address _toToken,
        uint256 _toAmount,
        bool customPath
    )
        public
        payable
        onlyRedeemable(_toToken)
        returns (address[] memory path, uint256[] memory amounts)
    {
        // calculate path & amounts
        // ** Why are we using WMATIC token when we're supposed to be using MATIC?
        address fromToken = eligibleTokenAddresses["WMATIC"];

        if (customPath) {
            // custom direct path
            path = generatePath(fromToken, _toToken, customPath);
        } else {
            // business as usual
            path = generatePath(fromToken, _toToken);
        }

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
