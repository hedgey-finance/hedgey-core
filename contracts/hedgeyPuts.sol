contract HedgeyPutsV2 is ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    address public asset; 
    address public pymtCurrency; 
    uint public assetDecimals;
    address public uniPair;
    address public unindex0;
    address public unindex1;
    address payable public weth = ; //input wrapped ETH      
    uint public fee;
    bool public feeCollectorSet; //set to false until the staking contract has been defined
    address payable public feeCollector;
    uint public p = 0; 
    address public uniFactory = ; //input AMM factory
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
        uniPair = IUniswapV2Factory(uniFactory).getPair(_asset, _pymtCurrency);
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
    

    struct Put {
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

    mapping (uint => Put) public puts;

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
        require(msg.sender == feeCollector, "only fee collector");
        fee = _fee;
    }

    function changeCollector(address payable _collector, bool _set) external returns (bool) {
        require(msg.sender == feeCollector, "only fee collector");
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

    
    // PUT FUNCTIONS  **********************************************

    
    function newBid(uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "p: totalPurchase error: too small amount");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= _price, "p: insufficent purchase cash");
        depositPymt(pymtWeth, pymtCurrency, msg.sender, _price); //handles weth and token deposits into contract
        puts[p++] = Put(address(0x0), _assetAmt, _strike, _totalPurch, _price, _expiry, false, true, msg.sender, false);
        emit NewBid(p.sub(1), _assetAmt, _strike, _price, _expiry);
    }


    function cancelNewBid(uint _p) public nonReentrant {
        Put storage put = puts[_p];
        require(msg.sender == put.long, "p:only long can cancel a bid");
        require(!put.open, "p: put already open");
        require(!put.exercised, "p: put already exercised");
        require(put.short == address(0x0), "p: not a new bid"); 
        put.tradeable = false;
        put.exercised = true;
        withdrawPymt(pymtWeth, pymtCurrency, put.long, put.price);
        emit OptionCancelled(_p);
    }

    
    function sellOpenOptionToNewBid(uint _p, uint _q, uint _price) payable public nonReentrant {
        Put storage openPut = puts[_p];
        Put storage newBid = puts[_q];
        require(_p != _q, "p: wrong sale function");
        require(_price == newBid.price, "p: price changed before execution");
        require(msg.sender == openPut.long, "p: you dont own this");
        require(openPut.strike == newBid.strike, "p: not the right strike");
        require(openPut.assetAmt == newBid.assetAmt, "p: not the right assetAmt");
        require(openPut.expiry == newBid.expiry, "p: not the right expiry");
        require(newBid.short == address(0x0), "p: newBid is not new");
        require(openPut.open && !newBid.open && newBid.tradeable && !openPut.exercised && !newBid.exercised && openPut.expiry > now && newBid.expiry > now, "something is wrong");
        //close out our new bid
        newBid.exercised = true;
        newBid.tradeable = false;
        uint feePymt = (newBid.price * fee).div(1e4);
        uint remainder = newBid.price.sub(feePymt);
        withdrawPymt(pymtWeth, pymtCurrency, openPut.long, remainder);
        SafeERC20.safeTransfer(IERC20(pymtCurrency), feeCollector, feePymt);
        if (feeCollectorSet) {
            IHedgeyStaking(feeCollector).receiveFee(feePymt, pymtCurrency); //this simple expression will default to true if the fee collector hasn't been set, and if it has will run the specific receive fee function
        }
        //assign the put.long
        openPut.long = newBid.long;
        openPut.price = newBid.price;
        openPut.tradeable = false;
        emit OpenOptionSold(_p, _q, openPut.long, _price);
    }

    
    function sellNewOption(uint _p, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        Put storage put = puts[_p];
        require(put.strike == _strike && put.assetAmt == _assetAmt && put.price == _price && put.expiry == _expiry, "p details mismatch: something has changed before execution");
        require(put.short == address(0x0));
        require(msg.sender != put.long, "p: you already own this");
        require(put.expiry > now, "p: This is already expired");
        require(put.tradeable, "p: not tradeable");
        require(!put.open, "p: put not open");
        require(!put.exercised, "p: this has been exercised");
        uint feePymt = (put.price * fee).div(1e4);
        uint shortPymt = (put.totalPurch).add(feePymt).sub(put.price); //net amount the short must send into the contract for escrow
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= shortPymt, "p: sell new option: insufficent collateral");
        depositPymt(pymtWeth, pymtCurrency, msg.sender, shortPymt);
        SafeERC20.safeTransfer(IERC20(pymtCurrency), feeCollector, feePymt);
        if (feeCollectorSet) {
            IHedgeyStaking(feeCollector).receiveFee(feePymt, pymtCurrency);
        }
        put.open = true;
        put.short = msg.sender;
        put.tradeable = false;
        emit NewOptionSold(_p);
    }


    function changeNewOption(uint _p, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public nonReentrant {
        Put storage put = puts[_p];
        require(put.long == msg.sender, "p: you do not own this put");
        require(!put.exercised, "p: this has been exercised");
        require(!put.open, "p: this is already open");
        require(put.tradeable, "p: this is not a tradeable option");
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "totalPurchase error: too small amount");
        //lets check if this is a new ask or new bid
        //if its a newAsk
        if (msg.sender == put.short) {
            uint refund = (put.totalPurch > _totalPurch) ? put.totalPurch.sub(_totalPurch) : _totalPurch.sub(put.totalPurch);
            uint oldPurch = put.totalPurch;
            put.strike = _strike;
            put.totalPurch = _totalPurch;
            put.assetAmt = _assetAmt;
            put.price = _price;
            put.expiry = _expiry;
            put.tradeable = true;
            if (oldPurch > _totalPurch) {
                withdrawPymt(pymtWeth, pymtCurrency, put.short, refund);
            } else if (oldPurch < _totalPurch) {
                uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
                require(balCheck >= refund, "p: not enough to change this put option");
                depositPymt(pymtWeth, pymtCurrency, msg.sender, refund);
            }
            emit OptionChanged(_p, _assetAmt, _strike, _price, _expiry);

        } else if (put.short == address(0x0)) {
            //its a newBid
            uint refund = (_price > put.price) ? _price.sub(put.price) : put.price.sub(_price);
            put.assetAmt = _assetAmt;
            put.strike = _strike;
            put.expiry = _expiry;
            put.totalPurch = _totalPurch;
            put.tradeable = true;
            if (_price > put.price) {
                put.price = _price;
                //we need to pull in more cash
                uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
                require(balCheck >= refund, "p: not enough cash to bid");
                depositPymt(pymtWeth, pymtCurrency, msg.sender, refund);
            } else if (_price < put.price) {
                put.price = _price;
                //need to refund the put bidder
                withdrawPymt(pymtWeth, pymtCurrency, put.long, refund);
            }
            emit OptionChanged(_p, _assetAmt, _strike, _price, _expiry);
                
        }
           
    }



    
     function newAsk(uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "p totalPurchase error: too small amount");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= _totalPurch, "p: you dont have enough collateral to write this option");
        depositPymt(pymtWeth, pymtCurrency, msg.sender, _totalPurch);
        puts[p++] = Put(msg.sender, _assetAmt, _strike, _totalPurch, _price, _expiry, false, true, msg.sender, false);
        emit NewAsk(p.sub(1), _assetAmt, _strike, _price, _expiry);
    }
    
    
    
    function cancelNewAsk(uint _p) public nonReentrant {
        Put storage put = puts[_p];
        require(msg.sender == put.short && msg.sender == put.long, "p: only short can change an ask");
        require(!put.open, "p: put already open");
        require(!put.exercised, "p: put already exercised");
        put.tradeable = false; 
        put.exercised = true;
        withdrawPymt(pymtWeth, pymtCurrency, put.short, put.totalPurch);
        emit OptionCancelled(_p);
    }


    
    function buyNewOption(uint _p, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        Put storage put = puts[_p];
        require(put.strike == _strike && put.assetAmt == _assetAmt && put.price == _price && put.expiry == _expiry, "p details mismatch: something has changed before execution");
        require(put.expiry > now, "p: This put is already expired");
        require(!put.exercised, "p: This has already been exercised");
        require(put.tradeable, "p: this is not ready to trade");
        require(msg.sender != put.short, "p: you are the short");
        require(put.short != address(0x0) && put.short == put.long, "p: this is not a newAsk");
        require(!put.open, "p: This put is already open");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= put.price, "p: not enough to buy this put");
        transferPymtWithFee(pymtWeth, pymtCurrency, msg.sender, put.short, _price);
        put.open = true; 
        put.long = msg.sender; 
        put.tradeable = false; 
        emit NewOptionBought(_p);
    }    


    

    function buyOptionFromAsk(uint _p, uint _q, uint _price) payable public nonReentrant {
        Put storage openShort = puts[_p];
        Put storage ask = puts[_q];
        require(_p != _q, "p: wrong function for buyback");
        require(_price == ask.price, "p details mismatch: something has changed before execution");
        require(msg.sender == openShort.short, "p: your not the short");
        require(ask.tradeable && !ask.exercised && ask.expiry > now,"p: ask issue");
        require(openShort.open && !openShort.exercised && openShort.expiry > now, "p: short issue");
        require(openShort.strike == ask.strike, "p: not the right strike");
        require(openShort.assetAmt == ask.assetAmt, "p: not the right assetAmt");
        require(openShort.expiry == ask.expiry, "p: not the right expiry");
        
        uint refund = openShort.totalPurch.sub(_price);
        uint feePymt = (_price * fee).div(1e4);
        withdrawPymt(pymtWeth, pymtCurrency, ask.long, _price.sub(feePymt));
        
        SafeERC20.safeTransfer(IERC20(pymtCurrency), feeCollector, feePymt);
        if (feeCollectorSet) {
            IHedgeyStaking(feeCollector).receiveFee(feePymt, pymtCurrency);
        }
        
        ask.exercised = true;
        ask.tradeable = false;
        ask.open = false;
        //now withdraw the openShort's total purchase collateral back to them
        withdrawPymt(pymtWeth, pymtCurrency, openShort.short, refund);
        openShort.short = ask.short;
        emit OpenShortRePurchased( _p, _q, openShort.short, _price); 
    }


    
    function setPrice(uint _p, uint _price, bool _tradeable) public {
        Put storage put = puts[_p];
        require((msg.sender == put.long && msg.sender == put.short) || (msg.sender == put.long && put.open), "p: you cant change the price");
        require(put.expiry > now, "p: already expired");
        require(!put.exercised, "p: already exercised");
        put.price = _price;
        put.tradeable = _tradeable;
        emit PriceSet(_p, _price, _tradeable);
    }

    
    
    function buyOpenOption(uint _p, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public nonReentrant {
        Put storage put = puts[_p];
        require(put.strike == _strike && put.assetAmt == _assetAmt && put.price == _price && put.expiry == _expiry, "p details mismatch: something has changed before execution");
        require(msg.sender != put.long, "p: You already own this"); 
        require(put.open, "p: This put isnt opened yet"); 
        require(put.expiry >= now, "p: This put is already expired");
        require(!put.exercised, "p: This has already been exercised!");
        require(put.tradeable, "p: put not tradeable");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= put.price, "p: not enough to buy this put");
        transferPymtWithFee(pymtWeth, pymtCurrency, msg.sender, put.long, _price);
        if (msg.sender == put.short) {
            withdrawPymt(pymtWeth, pymtCurrency, put.short, put.totalPurch);//send the money back to the put writer
            put.exercised = true;
            put.open = false;
        }
        
        put.tradeable = false;
        put.long = msg.sender;
        emit OpenOptionPurchased(_p);
    }

   
    function exercise(uint _p) payable public nonReentrant {
        Put storage put = puts[_p];
        require(put.open, "p: This isnt open");
        require(put.expiry >= now, "p: This put is already expired");
        require(!put.exercised, "p: This has already been exercised!");
        require(msg.sender == put.long, "p: You dont own this put");
        uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
        require(balCheck >= put.assetAmt, "p: not enough of the asset to close this put");
        put.exercised = true;
        put.open = false;
        put.tradeable = false;
        if (assetWeth) {
            require(msg.value == put.assetAmt, "p: eth mismatch, transferring the incorrect amount");
        }
        transferPymt(assetWeth, asset, msg.sender, put.short, put.assetAmt);
        withdrawPymt(pymtWeth, pymtCurrency, msg.sender, put.totalPurch);
        emit OptionExercised(_p, false);
    }

    
    function cashClose(uint _p, bool dummy) payable public nonReentrant {
        require(cashCloseOn, "p: This is not setup to cash close");
        Put storage put = puts[_p];
        require(put.open, "p: This isnt open");
        require(put.expiry >= now, "p: This put is already expired");
        require(!put.exercised, "p: This has already been exercised!");
        require(msg.sender == put.long, "p: You dont own this put");
        uint pymtEst = estIn(put.assetAmt);
        require(pymtEst < put.totalPurch, "p: this put is not in the money"); 
        address to = assetWeth ? address(this) : put.short;
        put.exercised = true;
        put.open = false;
        put.tradeable = false;
        swap(pymtCurrency, put.assetAmt, pymtEst, to);
        if (assetWeth) {
            withdrawPymt(assetWeth, asset, put.short, put.assetAmt);
        }
        put.totalPurch -= pymtEst;  
        
        withdrawPymt(pymtWeth, pymtCurrency, put.long, put.totalPurch);
        emit OptionExercised(_p, true);
    }
    
    
    function returnExpired(uint _p) payable public nonReentrant {
        Put storage put = puts[_p];
        require(!put.exercised, "p: This has been exercised");
        require(put.expiry < now, "p: Not expired yet");
        require(msg.sender == put.short, "p: You cant do that");
        put.tradeable = false;
        put.open = false;
        put.exercised = true;
        withdrawPymt(pymtWeth, pymtCurrency, put.short, put.totalPurch);//send back their deposit
        emit OptionReturned(_p);
    }

    
    function rollExpired(uint _p, uint _assetAmt, uint _newStrike, uint _price, uint _newExpiry) payable public nonReentrant {
        Put storage put = puts[_p];
        require(!put.exercised, "p: This has been exercised");
        require(put.expiry < now, "p: Not expired yet");
        require(msg.sender == put.short, "p: You cant do that");
        require(_newExpiry > now, "p: this is already in the past");
        uint _totalPurch = (_assetAmt).mul(_newStrike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "totalPurchase error: too small amount");
        uint refund = (_totalPurch > put.totalPurch) ? _totalPurch.sub(put.totalPurch) : put.totalPurch.sub(_totalPurch);
        put.open = false;
        put.exercised = true;
        put.tradeable = false;
        if (_totalPurch > put.totalPurch) {
            uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
            require(balCheck >= refund, "p: you dont have enough collateral to sell this option");
            depositPymt(pymtWeth, pymtCurrency, msg.sender, refund);
        } else if (_totalPurch < put.totalPurch) {
            withdrawPymt(pymtWeth, pymtCurrency, msg.sender, refund);
        }
        puts[p++] = Put(msg.sender, _assetAmt, _newStrike, _totalPurch, _price, _newExpiry, false, true, msg.sender, false);
        emit OptionRolled(_p, p.sub(1), _assetAmt, _newStrike, _price, _newExpiry);
    }

    //************SWAP SPECIFIC FUNCTIONS USED FOR THE CASH CLOSE METHODS***********************/

    
    function swap(address token, uint out, uint _in, address to) internal {
        SafeERC20.safeTransfer(IERC20(token), uniPair, _in);
        if (token == unindex0) {
            IUniswapV2Pair(uniPair).swap(0, out, to, new bytes(0));
        } else {
            IUniswapV2Pair(uniPair).swap(out, 0, to, new bytes(0));
        }
        
    }

    function estIn(uint _assetAmt) public view returns (uint cash) {
        (uint resA, uint resB, uint b) = IUniswapV2Pair(uniPair).getReserves();
        cash = (unindex0 == pymtCurrency) ? UniswapV2Library.getAmountIn(_assetAmt, resA, resB) : UniswapV2Library.getAmountIn(_assetAmt, resB, resA);
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
