$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'bitcoin'
require 'logger'
require 'timecop'
require 'webmock/rspec'

RSpec.configure do |config|
  config.before(:each) do |example|
    if example.metadata[:network]
      Bitcoin.chain_params = example.metadata[:network]
    else
      Bitcoin.chain_params = :testnet
    end
    if example.metadata[:use_secp256k1]
      use_secp256k1
    else
      use_ecdsa_gem
    end
  end
end

def use_secp256k1
  host_os = RbConfig::CONFIG['host_os']
  case host_os
    when /darwin|mac os/
      ENV['SECP256K1_LIB_PATH'] = File.expand_path('lib/libsecp256k1.dylib', File.dirname(__FILE__))
    when /linux/
      ENV['SECP256K1_LIB_PATH'] = File.expand_path('lib/libsecp256k1.so', File.dirname(__FILE__))
    else
      raise "#{host_os} is an unsupported os."
  end
end

def use_ecdsa_gem
  ENV['SECP256K1_LIB_PATH'] = nil
end

def fixture_file(relative_path)
  file = File.read(fixture_path(relative_path))
  JSON.parse(file)
end

def fixture_path(relative_path)
  File.join(File.dirname(__FILE__), 'fixtures', relative_path)
end

def load_block(hash)
  File.read(File.join(File.dirname(__FILE__), 'fixtures', "block/#{hash}"))
end

def load_payment(file_name)
  File.read(File.join(File.dirname(__FILE__), 'fixtures', "payments/#{file_name}"))
end

TEST_DB_PATH = "#{Dir.tmpdir}/#{ENV['TEST_ENV_NUMBER']}/spv"

def create_test_chain
  FileUtils.rm_r(TEST_DB_PATH) if Dir.exist?(TEST_DB_PATH)
  Bitcoin::Store::SPVChain.new(Bitcoin::Store::DB::LevelDB.new(TEST_DB_PATH))
end

TEST_WALLET_PATH = "#{Dir.tmpdir}/#{ENV['TEST_ENV_NUMBER']}/wallet-test/"

def test_wallet_path(wallet_id = 1)
  "#{TEST_WALLET_PATH}wallet#{wallet_id}/"
end

def create_test_wallet(wallet_id = 1, purpose = Bitcoin::Wallet::Account::PURPOSE_TYPE[:native_segwit])
  path = test_wallet_path(wallet_id)
  FileUtils.rm_r(path) if Dir.exist?(path)
  Bitcoin::Wallet::Base.create(wallet_id, TEST_WALLET_PATH, purpose)
end

def test_master_key
  words = %w(abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about)
  Bitcoin::Wallet::MasterKey.recover_from_words(words)
end

TEST_UTXO_DB_PATH = Dir.tmpdir + '/db/test_utxo'

def create_test_utxo_db()
  FileUtils.rm_r(TEST_UTXO_DB_PATH) if Dir.exist?(TEST_UTXO_DB_PATH)
  Bitcoin::Store::UtxoDB.new(TEST_UTXO_DB_PATH)
end

def create_test_spv
  block = double('block')
  allow(block).to receive(:height).and_return(101)

  chain = double('chain')
  allow(chain).to receive(:latest_block).and_return(block)

  spv = double('spv')
  allow(spv).to receive(:chain).and_return(chain)
  allow(spv).to receive(:broadcast).and_return(nil)
  allow(spv).to receive(:add_observer).and_return(nil)
  spv
end

module Bitcoin
  autoload :TestScriptParser, 'bitcoin/script/test_script_parser'
end

RSpec::Matchers.define :custom_object do |clazz, properties|
  match do |actual|
    return false unless actual.is_a?(clazz)
    properties.each do |key, value|
      return false unless actual.send(key) == value
    end
    true
  end
end