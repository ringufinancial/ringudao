const axios = require('axios')
const Web3 = require('web3')
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
		+ '&offset=0'
		+ '&sort=asc'
		+ '&apikey=' + key;

const init = async () => {
	
	var counter = 0;
	
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
				console.log(from_addr + ": " + decoded);
				counter = counter + 1;
		}
	}
	
	console.log("Total Nodes: " + counter)
}

init();