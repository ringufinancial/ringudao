const axios = require('axios')
const Web3 = require('web3')
var moment = require('moment');  
const HashMap = require('hashmap');
const rpcURL = 'https://polygon-rpc.com/' // Your RCkP URL goes here
const web3 = new Web3(rpcURL)
const key = 'MY_API_KEY';

var url = 'https://api.polygonscan.com/api'
		+ '?module=account'
		+ '&action=txlist'
		+ '&address=0x8258fDDF7E0477B8DfF86970813Ce5D333C88B57'
		+ '&startblock=0'
		+ '&endblock=99999999'
		+ '&page=10'
		// + '&offset=0'
		+ '&offset=0'
		+ '&sort=asc'
		+ '&apikey=' + key;

const init = async () => {
	
	var counter = 0;
	
	var nodeInfoList = [];
	
	const res = await axios.get(url);
	for (i in res.data.result) {
		var entry = res.data.result[i];
		var input = entry.input;
		if (input.indexOf("0x8f0ba4ca") == 0 
			&& entry.txreceipt_status == 1) {
				var from_addr = entry.from;
				var decoded = web3.utils.toAscii(input);
				decoded = decoded.replace(/[\W_]+/g," "); // strip non-word
				decoded = decoded.trim(); // strip white space
				// console.log(from_addr + ": " + decoded);
				counter = counter + 1;
				var nodeInfo = {
					"address": from_addr,
					"name": decoded,
					"createdTs": parseInt(entry.timeStamp),
					"lastClaim": parseInt(entry.timeStamp), // default, updated later
					"hadLastClaim": false
				}
				nodeInfoList.push(nodeInfo);
		}
	}
	
	var singleCashoutCounter = 0;
	
	var cashOutAllNodeTimeStampMap = new HashMap();
	var cashOutSingleNodeTimeStampMap = new HashMap();
	
	for (i in res.data.result) {
		var entry = res.data.result[i];
		var input = entry.input;
		if (input.indexOf("0x65bfe430") == 0 
				&& entry.txreceipt_status == 1) {
			singleCashoutCounter = singleCashoutCounter + 1;
			var from_addr = entry.from;
			var firstIndex = input.substring(9).replace(/^0+/, "");
			var blockTimeStamp = parseInt(firstIndex, 16);
			var nodeKey = from_addr + ":" + blockTimeStamp;
			var nodeSingleCashOutInfo = {
				"address": from_addr,
				"lastClaim": parseInt(entry.timeStamp),
				"blocktime": blockTimeStamp				
			}

			cashOutSingleNodeTimeStampMap.set(nodeKey, nodeSingleCashOutInfo);
		}
		else if (input.indexOf("0x54557973") == 0 
			&& entry.txreceipt_status == 1) {
				
				var from_addr = entry.from;
				var nodeCashOutInfo = {
					"address": from_addr,
					"lastClaim": parseInt(entry.timeStamp) 
				}
				cashOutAllNodeTimeStampMap.set(from_addr, nodeCashOutInfo);
		}
	}
	
	/*
	 * Combine latest Checkout All Timestamps with the nodes
	 */
	
	console.log("RINGU NODERewardManagement Data Export");
	console.log("-----------------------------------------------");
	var hadLastClaimCount = 0;
	
	for (i in nodeInfoList) {

		// single node last claim time?
		
		var nodeKey = nodeInfoList[i].address + ":" + nodeInfoList[i].createdTs;
		var lastSingleCashoutBlockInfo = cashOutSingleNodeTimeStampMap.get(nodeKey);
		
		var singleNodeClaimTime = 0;
		var allNodeClaimTime = 0;
		
		if (lastSingleCashoutBlockInfo != undefined) {
			// console.log(nodeInfoList[i]);
			singleNodeClaimTime = lastSingleCashoutBlockInfo.lastClaim
		}
		
		// all nodes last claim time?
		
		var lastCashoutBlockInfo = cashOutAllNodeTimeStampMap.get(nodeInfoList[i].address);
		if (lastCashoutBlockInfo != undefined) {
			allNodeClaimTime = lastCashoutBlockInfo.lastClaim
			
		}
		
		if (allNodeClaimTime > singleNodeClaimTime) {
			if (lastCashoutBlockInfo != undefined) {

				// is this a case where the last "cashout all" was done before they created this node?
				// if so ignore this new timestamp
				if (nodeInfoList[i].createdTs < lastCashoutBlockInfo.lastClaim) {
					nodeInfoList[i].lastClaim = lastCashoutBlockInfo.lastClaim;
					nodeInfoList[i].hadLastClaim = true;
					hadLastClaimCount++;
				}
			}
		} else {
			if (lastSingleCashoutBlockInfo != undefined) {
				nodeInfoList[i].lastClaim = lastSingleCashoutBlockInfo.lastClaim;
				nodeInfoList[i].hadLastClaim = true;
				hadLastClaimCount++;
			}
		}
		
		var createdTsFormatted = moment.unix(nodeInfoList[i].createdTs).format('YYYY-MM-DDTHH:mm:ssZ');
		nodeInfoList[i].createdTsFormatted = createdTsFormatted;
		
		var lastClaimFormatted = moment.unix(nodeInfoList[i].lastClaim).format('YYYY-MM-DDTHH:mm:ssZ');
		nodeInfoList[i].lastClaimTsFormatted = lastClaimFormatted;
		console.log(nodeInfoList[i]);

	}
	console.log("-----------------------------------------------");
	console.log("Total Nodes: " + counter);
	console.log("Total Nodes With Last Claim Times: " + hadLastClaimCount);
	
	// console.log("SingleCashoutCounter: " + singleCashoutCounter);
	
}

init();