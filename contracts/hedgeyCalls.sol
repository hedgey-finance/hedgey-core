contract HedgeyCallsV2 is ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    address public asset;
    address public pymtCurrency;
    uint public assetDecimals;
    address public uniPair; 
    address public unindex0;
    address public unindex1;
    address payable public weth = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83; //wrapped ftm 
    uint public fee;
    address payable public feeCollector;
    bool public feeCollectorSet;
    uint public c = 0;
    address public uniFactory = 0xEF45d134b73241eDa7703fa787148D9C9F4950b0; //spirit swap factory
    bool private assetWeth;
    bool private pymtWeth;
    bool public cashCloseOn;
    

    constructor(address _asset, address _pymtCurrency, address payable _feeCollector, uint _fee, bool _feeCollectorSet) public {
        asset = _asset;
        pymtCurrency = _pymtCurrency;
        feeCollector = _feeCollector;
        fee = _fee;
        feeCollectorSet = _feeCollectorSet;
        assetDecimals = IERC20(_asset).decimals();
        uniPair = IUniswapV2Factory(uniFactory).getPair(asset, pymtCurrency);
        if (uniPair == address(0x0)) {
            cashCloseOn = false;
            unindex0 = address(0x0);
            unindex1 = address(0x0);
        } else {
            cashCloseOn = true;
            unindex0 = IUniswapV2Pair(uniPair).token0();
            unindex1 = IUniswapV2Pair(uniPair).token1();
        }
        
        if (_asset == weth) {
            assetWeth = true;
            pymtWeth = false;
        } else if (_pymtCurrency == weth) {
            assetWeth = false;
            pymtWeth = true;
        } else {
            assetWeth = false;
            pymtWeth = false;
        }
    }
    
    struct Call {
        address payable short;
        uint assetAmt;
        uint strike;
        uint totalPurch;
        uint price;
        uint expiry;
        bool open;
        bool tradeable;
        address payable long;
        bool exercised;
    }

    
    mapping (uint => Call) public calls;

    
    //internal and setup functions

    receive() external payable {    
    }

    function depositPymt(bool _isWeth, address _token, address _sender, uint _amt) internal {
        if (_isWeth) {
            require(msg.value == _amt, "deposit issue: sending in wrong amount of eth");
            IWETH(weth).deposit{value: _amt}();
            assert(IWETH(weth).transfer(address(this), _amt));
        } else {
            SafeERC20.safeTransferFrom(IERC20(_token), _sender, address(this), _amt);
        }
    }

    function withdrawPymt(bool _isWeth, address _token, address payable to, uint _amt) internal {
        if (_isWeth && (!Address.isContract(to))) {
            //if the address is a contract - then we should actually just send WETH out to the contract, else send the wallet eth
            IWETH(weth).withdraw(_amt);
            to.transfer(_amt);
        } else {
            SafeERC20.safeTransfer(IERC20(_token), to, _amt);
        }
    }

    function transferPymt(bool _isWETH, address _token, address from, address payable to, uint _amt) internal {
        if (_isWETH) {
            if (!Address.isContract(to)) {
                to.transfer(_amt);
            } else {
                // we want to deliver WETH from ETH here for better handling at contract
                IWETH(weth).deposit{value: _amt}();
                assert(IWETH(weth).transfer(to, _amt));
            }
        } else {
            SafeERC20.safeTransferFrom(IERC20(_token), from, to, _amt);         
        }
    }

    function transferPymtWithFee(bool _isWETH, address _token, address from, address payable to, uint _total) internal {
        uint _fee = (_total * fee).div(1e4);
        uint _amt = _total.sub(_fee);
        if (_isWETH) {
            require(msg.value == _total, "transfer issue: wrong amount of eth sent");
        }
        transferPymt(_isWETH, _token, from, to, _amt); //transfer the stub to recipient
        transferPymt(_isWETH, _token, from, feeCollector, _fee); //transfer fee to fee collector
        if (feeCollectorSet) {
            IHedgeyStaking(feeCollector).receiveFee(_fee, _token);
        }    
    }


    
    function changeFee(uint _fee) external {
        require(msg.sender == feeCollector);
        fee = _fee;
    }

    function changeCollector(address payable _collector, bool _set) external returns (bool) {
        require(msg.sender == feeCollector);
        feeCollector = _collector;
        feeCollectorSet = _set; //this tells us if we've set our fee collector to the smart contract handling the fees, otherwise keep false
        return _set;
    }

    
    function updateAMM() public {
        uniPair = IUniswapV2Factory(uniFactory).getPair(asset, pymtCurrency);
        if (uniPair == address(0x0)) {
            cashCloseOn = false;
            unindex0 = address(0x0);
            unindex1 = address(0x0);
        } else {
            cashCloseOn = true;
            unindex0 = IUniswapV2Pair(uniPair).token0();
            unindex1 = IUniswapV2Pair(uniPair).token1();
        }
        emit AMMUpdate(cashCloseOn);
        
    }

    //CALL FUNCTIONS GOING HERE**********************************************************

    
    function newBid(uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "c: totalPurchase error: too small amount");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= _price, "c: not enough cash to bid");
        depositPymt(pymtWeth, pymtCurrency, msg.sender, _price); 
        calls[c++] = Call(address(0x0), _assetAmt, _strike, _totalPurch, _price, _expiry, false, true, msg.sender, false);
        emit NewBid(c.sub(1), _assetAmt, _strike, _price, _expiry);
    }
    
    
    function cancelNewBid(uint _c) public nonReentrant {
        Call storage call = calls[_c];
        require(msg.sender == call.long, "c: only long can cancel a bid");
        require(!call.open, "c: call already open");
        require(!call.exercised, "c: call already exercised");
        require(call.short == address(0x0), "c: this is not a new bid");
        call.tradeable = false;
        call.exercised = true;
        withdrawPymt(pymtWeth, pymtCurrency, call.long, call.price);
        emit OptionCancelled(_c);
    }

    
    function sellOpenOptionToNewBid(uint _c, uint _d, uint _price) payable public nonReentrant {
        Call storage openCall = calls[_c];
        Call storage newBid = calls[_d];
        require(_c != _d, "c: wrong sale function");
        require(_price == newBid.price, "c: price changed before you could execute");
        require(msg.sender == openCall.long, "c: you dont own this");
        require(openCall.strike == newBid.strike, "c: not the right strike");
        require(openCall.assetAmt == newBid.assetAmt, "c: not the right assetAmt");
        require(openCall.expiry == newBid.expiry, "c: not the right expiry");
        require(newBid.short == address(0x0), "c: this is not a new bid"); //newBid always sets the short address to 0x0
        require(openCall.open && !newBid.open && newBid.tradeable && !openCall.exercised && !newBid.exercised && openCall.expiry > now && newBid.expiry > now, "something is wrong");
        newBid.exercised = true;
        newBid.tradeable = false;
        uint feePymt = (newBid.price * fee).div(1e4);
        uint shortPymt = newBid.price.sub(feePymt);
        withdrawPymt(pymtWeth, pymtCurrency, openCall.long, shortPymt);
        SafeERC20.safeTransfer(IERC20(pymtCurrency), feeCollector, feePymt);
        if (feeCollectorSet) {
            IHedgeyStaking(feeCollector).receiveFee(feePymt, pymtCurrency); //this simple expression will default to true if the fee collector hasn't been set, and if it has will run the specific receive fee function
        }
        openCall.long = newBid.long;
        openCall.price = newBid.price;
        openCall.tradeable = false;
        emit OpenOptionSold( _c, _d, openCall.long, _price);
    }

    
    function sellNewOption(uint _c, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public nonReentrant {
        Call storage call = calls[_c];
        require(call.strike == _strike && call.assetAmt == _assetAmt && call.price == _price && call.expiry == _expiry, "c details issue: something changed");
        require(call.short == address(0x0));
        require(msg.sender != call.long, "c: you are the long");
        require(call.expiry > now, "c: This is already expired");
        require(call.tradeable, "c: not tradeable");
        require(!call.open, "c: call already open");
        require(!call.exercised, "c: this has been exercised");
        uint feePymt = (call.price * fee).div(1e4);
        uint shortPymt = (call.price).sub(feePymt);
        uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
        require(balCheck >= call.assetAmt, "c: not enough cash to bid");
        depositPymt(assetWeth, asset, msg.sender, call.assetAmt);
        SafeERC20.safeTransfer(IERC20(pymtCurrency), feeCollector, feePymt);
        if (feeCollectorSet) {
            IHedgeyStaking(feeCollector).receiveFee(feePymt, pymtCurrency);
        }
        withdrawPymt(pymtWeth, pymtCurrency, msg.sender, shortPymt);
        call.short = msg.sender;
        call.tradeable = false;
        call.open = true;
        emit NewOptionSold(_c);
    }


    function changeNewOption(uint _c, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public nonReentrant {
        Call storage call = calls[_c];
        require(call.long == msg.sender, "c: you do not own this call");
        require(!call.exercised, "c: this has been exercised");
        require(!call.open, "c: this is already open");
        require(call.tradeable, "c: this is not a tradeable option");
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "c: totalPurchase error: too small amount");
        //lets check if this is a new ask or new bid
        //if its a newAsk
        if (msg.sender == call.short) {
            uint refund = (call.assetAmt > _assetAmt) ? call.assetAmt.sub(_assetAmt) : _assetAmt.sub(call.assetAmt);
            call.strike = _strike;
            call.price = _price;
            call.expiry = _expiry;
            call.totalPurch = _totalPurch;
            call.tradeable = true;
            if (call.assetAmt > _assetAmt) {
                call.assetAmt = _assetAmt;
                withdrawPymt(assetWeth, asset, call.short, refund);
            } else if (call.assetAmt < _assetAmt) {
                call.assetAmt = _assetAmt;
                uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
                require(balCheck >= refund, "c: not enough to change this call option");
                depositPymt(assetWeth, asset, msg.sender, refund);
            }
            
            emit OptionChanged(_c, _assetAmt, _strike, _price, _expiry);

        } else if (call.short == address(0x0)) {
            //its a newBid
            uint refund = (_price > call.price) ? _price.sub(call.price) : call.price.sub(_price);
            call.assetAmt = _assetAmt;
            call.strike = _strike;
            call.price = _price;
            call.expiry = _expiry;
            call.totalPurch = _totalPurch;
            call.tradeable = true;
            if (_price > call.price) {
                call.price = _price;
                uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
                require(balCheck >= refund, "c: not enough cash to bid");
                depositPymt(pymtWeth, pymtCurrency, msg.sender, refund);
            } else if (_price < call.price) {
                call.price = _price;
                withdrawPymt(pymtWeth, pymtCurrency, call.long, refund);
            }
            
            emit OptionChanged(_c, _assetAmt, _strike, _price, _expiry);    
        }
           
    }

   
    function newAsk(uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "c: totalPurchase error: too small amount");
        uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
        require(balCheck >= _assetAmt, "c: not enough to sell this call option");
        depositPymt(assetWeth, asset, msg.sender, _assetAmt);
        calls[c++] = Call(msg.sender, _assetAmt, _strike, _totalPurch, _price, _expiry, false, true, msg.sender, false);
        emit NewAsk(c.sub(1), _assetAmt, _strike, _price, _expiry);
    }


    
    function cancelNewAsk(uint _c) public nonReentrant {
        Call storage call = calls[_c];
        require(msg.sender == call.short && msg.sender == call.long, "c: only short can change an ask");
        require(!call.open, "c: call already open");
        require(!call.exercised, "c: call already exercised");
        call.tradeable = false;
        call.exercised = true;
        withdrawPymt(assetWeth, asset, call.short, call.assetAmt);
        emit OptionCancelled(_c);
    }
    
    
    function buyNewOption(uint _c, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        Call storage call = calls[_c];
        require(call.strike == _strike && call.assetAmt == _assetAmt && call.price == _price && call.expiry == _expiry, "c details issue: something changed");
        require(msg.sender != call.short, "c: you cannot buy this");
        require(call.short != address(0x0) && call.short == call.long, "c: this option is not a new ask");
        require(call.expiry > now, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised");
        require(call.tradeable, "c: This isnt tradeable yet");
        require(!call.open, "c: This call is already open");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= call.price, "c: not enough to sell this call option");
        transferPymtWithFee(pymtWeth, pymtCurrency, msg.sender, call.short, _price);
        call.open = true;
        call.long = msg.sender;
        call.tradeable = false;
        emit NewOptionBought(_c);
    }

    
    function buyOptionFromAsk(uint _c, uint _d, uint _price) payable public nonReentrant {
        Call storage openShort = calls[_c];
        Call storage ask = calls[_d];
        require(msg.sender == openShort.short, "c: your not the short");
        require(ask.short != address(0x0), "c: this is a newBid");
        require(_price == ask.price, "c: price changed before executed");
        require(ask.tradeable && !ask.exercised && ask.expiry > now,"c: ask issue");
        require(openShort.open && !openShort.exercised && openShort.expiry > now, "c: short issue");
        require(openShort.strike == ask.strike, "c: strikes do not match");
        require(openShort.assetAmt == ask.assetAmt, "c: asset amount does not match");
        require(openShort.expiry == ask.expiry, "c: expiry does not match");
        require(_c != _d, "c: wrong function to buyback");
        //openShort pays the ask
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= ask.price, "c: not enough to buy this put");
        transferPymtWithFee(pymtWeth, pymtCurrency, openShort.short, ask.long, _price); //if newAsk then ask.long == ask.short, if openAsk then ask.long is the one receiving the payment
        //all the checks having been matched - now we assign the openAsk short to the openShort short position
        //then we close out the openAsk position
        ask.exercised = true;
        ask.tradeable = false;
        ask.open = false;
        //now withdraw the openShort's asset back to them
        withdrawPymt(assetWeth, asset, openShort.short, openShort.assetAmt);
        openShort.short = ask.short;
        emit OpenShortRePurchased( _c, _d, openShort.short, _price);
    }
    

    function setPrice(uint _c, uint _price, bool _tradeable) public {
        Call storage call = calls[_c];
        require((msg.sender == call.long && msg.sender == call.short) || (msg.sender == call.long && call.open), "c: you cant change the price");
        require(call.expiry > now, "c: already expired");
        require(!call.exercised, "c: already expired");
        call.price = _price; 
        call.tradeable = _tradeable;
        emit PriceSet(_c, _price, _tradeable);
    }


    function buyOpenOption(uint _c, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public nonReentrant {
        Call storage call = calls[_c];
        require(call.strike == _strike && call.assetAmt == _assetAmt && call.price == _price && call.expiry == _expiry, "c: something changed");
        require(msg.sender != call.long, "c: You already own this");
        require(call.open, "c: This call isnt opened yet");
        require(call.expiry >= now, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised");
        require(call.tradeable, "c: not tradeable");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= call.price, "c: not enough to sell this call option");
        transferPymtWithFee(pymtWeth, pymtCurrency, msg.sender, call.long, call.price);
        if (msg.sender == call.short) {
            call.exercised = true;
            call.open = false;
            withdrawPymt(assetWeth, asset, call.short, call.assetAmt);
        }
        call.tradeable = false;
        call.long = msg.sender;
        emit OpenOptionPurchased(_c);
    }


    
    function exercise(uint _c) payable public nonReentrant {
        Call storage call = calls[_c];
        require(call.open, "c: This isnt open");
        require(call.expiry >= now, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised!");
        require(msg.sender == call.long, "c: You dont own this call");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= call.totalPurch, "c: not enough to exercise this call option");
        call.exercised = true;
        call.open = false;
        call.tradeable = false;
        if(pymtWeth) {
            require(msg.value == call.totalPurch,"eth mismatch on value to purchase the asset");
        }
        transferPymt(pymtWeth, pymtCurrency, msg.sender, call.short, call.totalPurch);   
        withdrawPymt(assetWeth, asset, call.long, call.assetAmt);
        emit OptionExercised(_c, false);
    }


    
    function cashClose(uint _c, bool cashBack) payable public nonReentrant {
        require(cashCloseOn, "c: this pair cannot be cash closed");
        Call storage call = calls[_c];
        require(call.open, "c: This isnt open");
        require(call.expiry >= now, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised!");
        require(msg.sender == call.long, "c: You dont own this call");
   
        uint assetIn = estIn(call.totalPurch);
        require(assetIn < (call.assetAmt), "c: Underlying is not in the money");
        
        address to = pymtWeth ? address(this) : call.short;
        call.exercised = true;
        call.open = false;
        call.tradeable = false;
        swap(asset, call.totalPurch, assetIn, to);
        if (pymtWeth) {
            withdrawPymt(pymtWeth, pymtCurrency, call.short, call.totalPurch);
        }
        
        call.assetAmt -= assetIn;
        
        if (cashBack) {
            
            uint cashEst = estCashOut(call.assetAmt);
            address _to = pymtWeth ? address(this) : call.long;
            swap(asset, cashEst, call.assetAmt, _to);
            if (pymtWeth) {
                withdrawPymt(pymtWeth, pymtCurrency, call.long, cashEst); 
            }
        } else {
            withdrawPymt(assetWeth, asset, call.long, call.assetAmt);
        }
        
        emit OptionExercised(_c, true);
    }


    

    
    function returnExpired(uint _c) public nonReentrant {
        Call storage call = calls[_c];
        require(!call.exercised, "c: This has been exercised");
        require(call.expiry < now, "c: Not expired yet"); 
        require(msg.sender == call.short, "c: You cant do that");
        call.tradeable = false;
        call.open = false;
        call.exercised = true;
        withdrawPymt(assetWeth, asset, call.short, call.assetAmt);
        emit OptionReturned(_c);
    }

    
    function rollExpired(uint _c, uint _assetAmt, uint _newStrike, uint _price, uint _newExpiry) payable public nonReentrant {
        Call storage call = calls[_c]; 
        require(!call.exercised, "c: This has been exercised");
        require(call.expiry < now, "c: Not expired yet"); 
        require(msg.sender == call.short, "c: You cant do that");
        require(_newExpiry > now, "c: this is already in the past");
        uint refund = (call.assetAmt > _assetAmt) ? call.assetAmt.sub(_assetAmt) : _assetAmt.sub(call.assetAmt);
        uint _totalPurch = (_assetAmt).mul(_newStrike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "c: totalPurchase error: too small amount");
        call.tradeable = false;
        call.open = false;
        call.exercised = true;
        if (call.assetAmt > _assetAmt) {
            withdrawPymt(assetWeth, asset, call.short, refund); 
        } else if (call.assetAmt < _assetAmt) {
            uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
            require(balCheck >= refund, "c: not enough to change this call option");
            depositPymt(assetWeth, asset, msg.sender, refund); 
        }
        
        calls[c++] = Call(msg.sender, _assetAmt, _newStrike, _totalPurch, _price, _newExpiry, false, true, msg.sender, false);
        emit OptionRolled(_c, c.sub(1), _assetAmt, _newStrike, _price, _newExpiry);
    }

    

    //************SWAP SPECIFIC FUNCTIONS USED FOR THE CASH CLOSE METHODS***********************/

    
    function swap(address token, uint out, uint _in, address to) internal {
        SafeERC20.safeTransfer(IERC20(token), uniPair, _in); //sends the asset amount in to the swap
        if (token == unindex0) {
            IUniswapV2Pair(uniPair).swap(0, out, to, new bytes(0));
        } else {
            IUniswapV2Pair(uniPair).swap(out, 0, to, new bytes(0));
        }
        
    }

    function estCashOut(uint _assetAmt) public view returns (uint cash) {
        (uint resA, uint resB, uint b) = IUniswapV2Pair(uniPair).getReserves();
        cash = (unindex0 == asset) ? UniswapV2Library.getAmountOut(_assetAmt, resA, resB) : UniswapV2Library.getAmountOut(_assetAmt, resB, resA);
    }

    function estIn(uint _pymtAmt) public view returns (uint _assetIn) {
        (uint resA, uint resB, uint b) = IUniswapV2Pair(uniPair).getReserves();
        _assetIn = (unindex0 == asset) ? UniswapV2Library.getAmountIn(_pymtAmt, resA, resB) : UniswapV2Library.getAmountIn(_pymtAmt, resB, resA);
    }

   /***events*****/
    event NewBid(uint _i, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event NewAsk(uint _i, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event NewOptionSold(uint _i);
    event NewOptionBought(uint _i);
    event OpenOptionSold(uint _i, uint _j, address _long, uint _price);
    event OpenShortRePurchased(uint _i, uint _j, address _short, uint _price);
    event OpenOptionPurchased(uint _i);
    event OptionChanged(uint _i, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event PriceSet(uint _i, uint _price, bool _tradeable);
    event OptionExercised(uint _i, bool cashClosed);
    event OptionRolled(uint _i, uint _j, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event OptionReturned(uint _i);
    event OptionCancelled(uint _i);
    event AMMUpdate(bool _cashCloseOn);
}
