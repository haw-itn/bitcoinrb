require 'spec_helper'

describe 'Bitcoin::Wallet::UtxoHandler' do
  let(:handler) { Bitcoin::Wallet::UtxoHandler.new(spv, utxo_db) }
  let(:utxo_db) { create_test_utxo_db }
  let(:spv) { create_test_spv }
  let(:wallet) { create_test_wallet }

  before { allow(spv).to receive(:wallet).and_return(wallet) }

  after do
    utxo_db.close
    wallet.close
    FileUtils.rm_r(test_wallet_path(1))
  end

  context 'when node receives tx message' do
    subject { handler.update(:tx, message) }

    let(:funding_tx) do
      # create transaction to send to the wallet
      key = wallet.accounts.first.create_receive

      # default script is native_segwit
      script = Bitcoin::Script.to_p2wpkh(key.hash160)
      Bitcoin::Tx.new.tap do |tx|
        tx.inputs << Bitcoin::TxIn.new(out_point: Bitcoin::OutPoint.new('00' * 32, -1))
        tx.outputs << Bitcoin::TxOut.new(value: 600, script_pubkey: script)
      end
    end
    let(:out_point) { Bitcoin::OutPoint.from_txid(funding_tx.txid, 0)}

    context 'store utxo' do
      let(:message) { Bitcoin::Message::Tx.parse_from_payload(funding_tx.to_payload) }

      it 'should store watching utxo' do
        subject
        utxo = utxo_db.get_utxo(out_point)
        expect(utxo).not_to be_nil

        utxos = utxo_db.list_unspent_in_account(wallet.accounts.first)
        expect(utxos.size).to eq 1
      end
    end

    context 'delete utxo' do
      before do
        output = funding_tx.outputs[0]
        utxo_db.save_utxo(out_point, output.value, output.script_pubkey)
      end

      let(:message) { Bitcoin::Message::Tx.parse_from_payload(spending_tx.to_payload) }
      let(:spending_tx) do
        Bitcoin::Tx.new.tap do |tx|
          tx.inputs << Bitcoin::TxIn.new(out_point: Bitcoin::OutPoint.from_txid(funding_tx.txid, 0))
          # No outputs
        end
      end

      it 'should delete unspent utxo from utxo_db' do
        expect(utxo_db.get_utxo(out_point)).not_to be_nil
        subject
        expect(utxo_db.get_utxo(out_point)).to be_nil
        utxos = utxo_db.list_unspent_in_account(wallet.accounts.first)
        expect(utxos.size).to eq 0
      end
    end
  end

  context 'when node receives header message' do
    subject { handler.update(:header, {hash: '00' * 32, height: 101}) }

    # https://www.blockchain.com/btc/block/100014
    let(:payload) { '0100000082bb869cf3a793432a66e826e05a6fc37469f8efb7421dc880670100000000007f16c5962e8bd963659c793ce370d95f093bc7e367117b3c30c1f8fdd0d9728776381b4d4c86041b554b852907000000043612262624047ee87660be1a707519a443b1c1ce3d248cbfc6c15870f6c5daa2019f5b01d4195ecbc9398fbf3c3b1fa9bb3183301d7a1fb3bd174fcfa40a2b6541ed70551dd7e841883ab8f0b16bf04176b7d1480e4f0af9f3d4c3595768d06820d2a7bc994987302e5b1ac80fc425fe25f8b63169ea78e68fbaaefa59379bbf011d'.htb }
    let(:merkle_block) { Bitcoin::Message::MerkleBlock.parse_from_payload(payload) }

    # https://www.blockchain.com/btc/tx/652b0aa4cf4f17bdb31f7a1d308331bba91f3b3cbf8f39c9cb5e19d4015b9f01
    let(:tx) { Bitcoin::Tx.parse_from_payload('0100000001834537b2f1ce8ef9373a258e10545ce5a50b758df616cd4356e0032554ebd3c4000000008b483045022100e68f422dd7c34fdce11eeb4509ddae38201773dd62f284e8aa9d96f85099d0b002202243bd399ff96b649a0fad05fa759d6a882f0af8c90cf7632c2840c29070aec20141045e58067e815c2f464c6a2a15f987758374203895710c2d452442e28496ff38ba8f5fd901dc20e29e88477167fe4fc299bf818fd0d9e1632d467b2a3d9503b1aaffffffff0280d7e636030000001976a914f34c3e10eb387efe872acb614c89e78bfca7815d88ac404b4c00000000001976a914a84e272933aaf87e1715d7786c51dfaeb5b65a6f88ac00000000'.htb) }
    let(:out_point) { Bitcoin::OutPoint.from_txid('652b0aa4cf4f17bdb31f7a1d308331bba91f3b3cbf8f39c9cb5e19d4015b9f01', 0) }
    let(:script_pubkey) { Bitcoin::Script.parse_from_addr('n3hPq5zGqvQKCtLu3r2szQ5b1oAzBdfY9S') }

    let(:header) { Bitcoin::BlockHeader.parse_from_payload('0100000082bb869cf3a793432a66e826e05a6fc37469f8efb7421dc880670100000000007f16c5962e8bd963659c793ce370d95f093bc7e367117b3c30c1f8fdd0d9728776381b4d4c86041b554b8529'.htb) }

    context 'if merkleblock does not have received' do
      before do
        handler.pending_txs << tx
        utxo_db.save_utxo(out_point, 13_806_000_000, script_pubkey)
        allow(spv.chain).to receive(:find_entry_by_hash).and_return(Bitcoin::Store::ChainEntry.new(header, 100014))
      end

      it 'should not change block_height of the UTXO' do
        expect { subject }.not_to change { utxo_db.get_utxo(out_point).block_height }
      end

    end

    context 'if merkleblock has already received' do
      before do
        handler.pending_blocks << merkle_block
        handler.pending_txs << tx
        utxo_db.save_utxo(out_point, 13_806_000_000, script_pubkey)
        allow(spv.chain).to receive(:find_entry_by_hash).and_return(Bitcoin::Store::ChainEntry.new(header, 100014))
      end

      it 'update block_height of the UTXO' do
        expect { subject }.to change { utxo_db.get_utxo(out_point).block_height }.from(nil).to(100014)
      end

      it 'delete from pending blocks' do
        expect { subject }.to change { handler.pending_blocks.size }.from(1).to(0)
      end

      it 'can retrieve by block height' do
        subject
        expect(utxo_db.list_unspent(current_block_height: 100015, min: 1, max: 1, addresses: nil).size).to eq 1
      end
    end
  end

  context 'when receive merkleblock message' do
    subject { handler.update(:merkleblock, merkle_block) }

    # https://www.blockchain.com/btc/block/100014
    let(:payload) { '0100000082bb869cf3a793432a66e826e05a6fc37469f8efb7421dc880670100000000007f16c5962e8bd963659c793ce370d95f093bc7e367117b3c30c1f8fdd0d9728776381b4d4c86041b554b852907000000043612262624047ee87660be1a707519a443b1c1ce3d248cbfc6c15870f6c5daa2019f5b01d4195ecbc9398fbf3c3b1fa9bb3183301d7a1fb3bd174fcfa40a2b6541ed70551dd7e841883ab8f0b16bf04176b7d1480e4f0af9f3d4c3595768d06820d2a7bc994987302e5b1ac80fc425fe25f8b63169ea78e68fbaaefa59379bbf011d'.htb }
    let(:merkle_block) { Bitcoin::Message::MerkleBlock.parse_from_payload(payload) }

    let(:header) { Bitcoin::BlockHeader.parse_from_payload('0100000082bb869cf3a793432a66e826e05a6fc37469f8efb7421dc880670100000000007f16c5962e8bd963659c793ce370d95f093bc7e367117b3c30c1f8fdd0d9728776381b4d4c86041b554b8529'.htb) }

    context 'if node has not received header yet' do
      it 'add merkleblock to pending list' do
        allow(spv.chain).to receive(:find_entry_by_hash).and_return(nil)
        expect { subject }.to change { handler.pending_blocks.size }.from(0).to(1)
      end
    end

    context 'if node has received header' do
      # https://www.blockchain.com/btc/tx/652b0aa4cf4f17bdb31f7a1d308331bba91f3b3cbf8f39c9cb5e19d4015b9f01
      let(:tx) { Bitcoin::Tx.parse_from_payload('0100000001834537b2f1ce8ef9373a258e10545ce5a50b758df616cd4356e0032554ebd3c4000000008b483045022100e68f422dd7c34fdce11eeb4509ddae38201773dd62f284e8aa9d96f85099d0b002202243bd399ff96b649a0fad05fa759d6a882f0af8c90cf7632c2840c29070aec20141045e58067e815c2f464c6a2a15f987758374203895710c2d452442e28496ff38ba8f5fd901dc20e29e88477167fe4fc299bf818fd0d9e1632d467b2a3d9503b1aaffffffff0280d7e636030000001976a914f34c3e10eb387efe872acb614c89e78bfca7815d88ac404b4c00000000001976a914a84e272933aaf87e1715d7786c51dfaeb5b65a6f88ac00000000'.htb) }
      let(:out_point) { Bitcoin::OutPoint.from_txid('652b0aa4cf4f17bdb31f7a1d308331bba91f3b3cbf8f39c9cb5e19d4015b9f01', 0) }
      let(:script_pubkey) { Bitcoin::Script.parse_from_addr('n3hPq5zGqvQKCtLu3r2szQ5b1oAzBdfY9S') }

      before do
        utxo_db.save_utxo(out_point, 13_806_000_000, script_pubkey)
        handler.pending_txs << tx
        allow(spv.chain).to receive(:find_entry_by_hash).and_return(Bitcoin::Store::ChainEntry.new(header, 100014))
      end

      it 'update block_height of the UTXO' do
        expect { subject }.to change { utxo_db.get_utxo(out_point).block_height }.from(nil).to(100014)
      end

      it 'delete from pending txs' do
        expect { subject }.to change { handler.pending_txs.size }.from(1).to(0)
      end

      it 'can retrieve by block height' do
        subject
        expect(utxo_db.list_unspent(current_block_height: 100015, min: 1, max: 1, addresses: nil).size).to eq 1
      end
    end
  end
end
