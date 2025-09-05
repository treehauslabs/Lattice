//import XCTest
//@testable import Lattice
//
//final class LatticeTests: XCTestCase {
//    
//    func testBlockCreation() {
//        let transaction = Transaction(from: "alice", to: "bob", amount: 50.0)
//        let block = Block(index: 1, previousHash: "0000", transactions: [transaction])
//        
//        XCTAssertEqual(block.header.index, 1)
//        XCTAssertEqual(block.header.previousHash, "0000")
//        XCTAssertEqual(block.transactions.count, 1)
//        XCTAssertFalse(block.hash.isEmpty)
//    }
//    
//    func testTransactionCreation() {
//        let transaction = Transaction(from: "alice", to: "bob", amount: 100.0, fee: 1.0)
//        
//        XCTAssertFalse(transaction.id.isEmpty)
//        XCTAssertEqual(transaction.outputs.first?.amount, 100.0)
//        XCTAssertEqual(transaction.fee, 1.0)
//        XCTAssertTrue(transaction.isValid())
//    }
//    
//    func testBlockchainCreation() {
//        let blockchain = Blockchain()
//        
//        XCTAssertEqual(blockchain.blocks.count, 1) // Genesis block
//        XCTAssertTrue(blockchain.isChainValid())
//    }
//    
//    func testWalletCreation() {
//        let wallet = Wallet()
//        
//        XCTAssertFalse(wallet.privateKey.isEmpty)
//        XCTAssertFalse(wallet.publicKey.isEmpty)
//        XCTAssertFalse(wallet.address.isEmpty)
//        XCTAssertTrue(wallet.address.hasPrefix("1"))
//    }
//    
//    func testMining() {
//        let blockchain = Blockchain(difficulty: 1)
//        let wallet = Wallet()
//        
//        let transaction = Transaction.createCoinbaseTransaction(to: wallet.address, amount: 50.0)
//        blockchain.addTransaction(transaction)
//        
//        let minedBlock = blockchain.minePendingTransactions(miningRewardAddress: wallet.address)
//        
//        XCTAssertNotNil(minedBlock)
//        XCTAssertTrue(minedBlock!.hash.hasPrefix("0"))
//    }
//    
//    func testCryptoUtils() {
//        let keyPair = CryptoUtils.generateKeyPair()
//        
//        XCTAssertFalse(keyPair.privateKey.isEmpty)
//        XCTAssertFalse(keyPair.publicKey.isEmpty)
//        
//        let message = "Hello, Blockchain!"
//        let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey)
//        
//        XCTAssertNotNil(signature)
//        
//        if let sig = signature {
//            let isValid = CryptoUtils.verify(message: message, signature: sig, publicKeyHex: keyPair.publicKey)
//            XCTAssertTrue(isValid)
//        }
//    }
//    
//    func testValidator() {
//        let transaction = Transaction(from: "alice", to: "bob", amount: 50.0)
//        let validation = Validator.validateTransaction(transaction)
//        
//        XCTAssertTrue(validation.isValid)
//        XCTAssertTrue(validation.errors.isEmpty)
//    }
//    
//    func testAddressValidation() {
//        XCTAssertTrue(Wallet.validateAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"))
//        XCTAssertFalse(Wallet.validateAddress("invalid"))
//        XCTAssertFalse(Wallet.validateAddress(""))
//    }
//    
//    func testBlockchainBalance() {
//        let blockchain = Blockchain(difficulty: 1)
//        let alice = Wallet()
//        
//        blockchain.minePendingTransactions(miningRewardAddress: alice.address)
//        let balance = alice.getBalance(from: blockchain)
//        
//        XCTAssertEqual(balance, 100.0) // Mining reward
//    }
//}
