# frozen_string_literal: true

require_relative "CoinjarTriangleArbitrage/version"
require 'httparty'
require 'json'

module CoinjarTriangleArbitrage
  START_CURRENCY = 'GBP'
  END_CURRENCY = 'GBP'
  FIAT_DECIMAL_INITIAL_AMOUNT = 50.00
  class PublicClient
    include HTTParty
    headers {'accept' => 'application/json'}
    def initialize
    end
    def get_all_products
      request = self.class.get('https://api.exchange.coinjar.com/products',format: :plain)
      response = request.body.to_s
      # puts "all products response is #{response}"
      JSON.parse(response)
    end
    def ticker(id)
      id = id.to_s.upcase
      request = self.class.get("https://data.exchange.coinjar.com/products/#{id}/ticker",format: :plain)
      response = request.body.to_s
      # puts "ticker response is #{response} and id is #{id}"
      JSON.parse(response)
    end
  end
  class PrivateClient
    include HTTParty
    base_uri 'api.exchange.coinjar.com:443'
    headers 'Authorization' => "Bearer #{ENV['COINJAR_TRADES']}",'accept' => 'application/json'

    def initialize
    end
  end
  class Chain
    attr_accessor :result,:trade_one_price,:trade_two_price,:trade_three_price
    def initialize(public_client,chain_args)
      @public_client = public_client
      @chain_args = chain_args
      @result = calculate_result
      # only valid if the start currency and end currency are the same
      @profit = @result - FIAT_DECIMAL_INITIAL_AMOUNT
    end
    #BTC/GBP - BTC base - GBP pair
    def base_to_pair(base,pair,amount_of_base)
      @public_client.ticker("#{base}#{pair}")["ask"].to_f * amount_of_base.to_f
    end
    def pair_to_base(base,pair,amount_of_pair)
      amount_of_pair.to_f / @public_client.ticker("#{base}#{pair}")["ask"].to_f
    end
    def get_quote_based_on_trade_direction(pair,direction,amount)
      # puts pair.to_s
      # puts direction.to_s
      # puts amount.to_s
      if direction == :buy
        return pair_to_base(pair[0].upcase,pair[1].upcase,amount)
      elsif direction == :sell
        return base_to_pair(pair[0].upcase,pair[1].upcase,amount)
      end
    end
    def calculate_result
      @trade_one_price = get_quote_based_on_trade_direction(@chain_args[:start],@chain_args[:start_trade_direction],FIAT_DECIMAL_INITIAL_AMOUNT) # * 0.999
      @trade_two_price = get_quote_based_on_trade_direction(@chain_args[:middle],@chain_args[:middle_trade_direction],@trade_one_price) * 0.999
      @trade_three_price = get_quote_based_on_trade_direction(@chain_args[:ending],@chain_args[:ending_trade_direction],@trade_two_price) * 0.999
      @trade_one_price * @trade_two_price * @trade_three_price
    end
    def to_s
      "#{@chain_args} - result: #{@result} - #{START_CURRENCY == END_CURRENCY ? "profit = ".join(@profit.to_s) : "Please Manually Calculate For Now"}"
    end
  end
  class ChainFactory
    def initialize(public_client,all_product_ids,all_products)
      @all_products = all_products
      @public_client = public_client
      @all_product_ids = all_product_ids
      @start_currency = CoinjarTriangleArbitrage::START_CURRENCY
      @end_currency = CoinjarTriangleArbitrage::END_CURRENCY
      @split_ids = @all_product_ids.map {|id| id.split("/")}
      @start_pairs = find_starting_pairs
      @starting_trades = @start_pairs.select {|pair| pair[0] == @start_currency || pair[1] == @start_currency }
      @end_pairs = []
      if @start_currency == @end_currency
        @end_pairs = @start_pairs
      else
        @end_pairs = find_ending_pairs
      end
      @intermediate_pairs = find_intermediate_pairs
    end
    def find_starting_pairs
      @split_ids.select {|pair| @start_currency == pair[0] || @start_currency == pair[1]}
    end

    # problem here
    def find_intermediate_pairs
      sieved_pairs = []
      start_symbols = @starting_trades
      start_symbols = start_symbols.flatten.filter {|symbol| symbol != @start_currency.to_s }
      end_symbols = start_symbols
      if @start_currency != @end_currency
        end_symbols = @end_pairs.flatten.filter {|symbol| symbol != @end_currency.to_s }
      end
      start_symbols.each do |start|
        end_symbols.each do |ending|
          if @split_ids.any?([start,ending])
            sieved_pairs << [start,ending]
          end
          if @split_ids.any?([ending,start])
            sieved_pairs << [ending,start]
          end
        end
      end
      return sieved_pairs
    end

    def find_ending_pairs
      @split_ids.select {|pair| @end_currency == pair[0] || @end_currency == pair[1]}
    end
    def build_chains
      chains = []
      chain_args = {}
      @starting_trades.each do |start|
        @end_pairs.each do |ending|
          @intermediate_pairs.each do |middle|
            if (start[0] == middle[0] && middle[1] == ending[0])
              chain_args = {start: start,:start_trade_direction => :sell,middle:middle,:middle_trade_direction => :buy,ending:ending,:ending_trade_direction => :sell}
            elsif (start[1] == middle[0] && middle[1] == ending[1])
              chain_args = {start: start,:start_trade_direction => :buy,middle:middle,:middle_trade_direction => :buy,ending:ending,:ending_trade_direction => :buy}
            elsif (start[0] == middle[1] && middle[0] == ending[1])
              chain_args = {start: start,:start_trade_direction => :sell,middle:middle,:middle_trade_direction => :sell,ending:ending,:ending_trade_direction => :buy}
            elsif (start[0] == middle[1] && middle[1] == ending[0])
              chain_args = {start: start,:start_trade_direction => :sell,middle:middle,:middle_trade_direction => :buy,ending:ending,:ending_trade_direction => :sell}
            elsif (start[1] == middle[0] && middle[1] == ending[0])
              chain_args = {start: start,:start_trade_direction => :buy,middle:middle,:middle_trade_direction => :buy,ending:ending,:ending_trade_direction => :sell}
            elsif (start[0] == middle[1] && middle[0] == ending[0])
              chain_args = {start: start,:start_trade_direction => :sell,middle:middle,:middle_trade_direction => :sell,ending:ending,:ending_trade_direction => :sell}
            elsif (start[1] == middle[1]&& middle[0] == ending[0])
              chain_args = {start: start,:start_trade_direction => :buy,middle:middle,:middle_trade_direction => :sell,ending:ending,:ending_trade_direction => :sell}
            end
            # puts [start,middle,ending].to_s
            # puts chain_args.to_s
            chains.append(Chain.new(@public_client,chain_args))
          end
        end
      end
      return chains
    end
  end



  class Scout
    # include HTTParty
    # base_uri 'api.exchange.coinjar.com:443'
    # headers 'Authorization' => "Bearer #{ENV['COINJAR_TRADES']}",'accept' => 'application/json'

    def initialize
      @@public_client = CoinjarTriangleArbitrage::PublicClient.new
      @all_products = @@public_client.get_all_products
      @all_product_ids = @all_products.map { |currency| currency["name"] }
    end
    def run
      ChainFactory.new(@@public_client,@all_product_ids,@all_products).build_chains.sort_by {|chain| chain.result <=> chain.result}
    end
  end
end

puts CoinjarTriangleArbitrage::Scout.new.run.to_s