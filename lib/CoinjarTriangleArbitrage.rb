# frozen_string_literal: true

require_relative "CoinjarTriangleArbitrage/version"
require 'httparty'
require 'json'
require 'parallel'

module CoinjarTriangleArbitrage
  START_CURRENCY = 'GBP'
  END_CURRENCY = 'GBP'
  FIAT_DECIMAL_INITIAL_AMOUNT = 50.00
  TRADING = true
  MIN_PROFIT = 0.2
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
    base_uri 'https://api.exchange.coinjar.com'
    headers 'Authorization' => "Bearer #{ENV['COINJAR_TRADES']}",'accept' => 'application/json','Content-Type' => 'application/json'

    def initialize
    end
    # {oid:"number"}
    def place_order(product_id,price,buy_or_sell,size,type = "LMT")
      JSON.parse(self.class.post('/orders',body: JSON.generate({"type" => type.to_s,"size" => size.to_s,"product_id" => product_id.to_s,"side" => buy_or_sell.to_s,"price" => price.to_s})).to_s)
    end
    def get_order(order_id)
      JSON.parse(self.class.get("/orders/#{order_id.to_s}").to_s).to_h
    end
  end
  class Chain
    attr_accessor :result,:chain_args,:trade_one_quote,:trade_two_quote,:trade_three_quote,:profit,:trade_one_price,:trade_two_price,:trade_three_price
    def initialize(public_client,chain_args)
      @public_client = public_client
      @chain_args = chain_args
      @result = calculate_result
      # only valid if the start currency and end currency are the same
      @profit = @result - FIAT_DECIMAL_INITIAL_AMOUNT
    end
    #BTC/GBP - BTC base - GBP pair
    def base_to_pair(base,pair)
      @public_client.ticker("#{base}#{pair}")["ask"].to_f * 1
    end
    def pair_to_base(base,pair)
      1 / @public_client.ticker("#{base}#{pair}")["ask"].to_f
    end
    def get_quote_based_on_trade_direction(pair,direction)
      # puts pair.to_s
      # puts direction.to_s
      # puts amount.to_s
      if direction == :buy
        return pair_to_base(pair[0].upcase,pair[1].upcase)
      elsif direction == :sell
        return base_to_pair(pair[0].upcase,pair[1].upcase)
      end
    end
    def calculate_result
      @trade_one_quote = get_quote_based_on_trade_direction(@chain_args[:start],@chain_args[:start_trade_direction])
      @trade_two_quote = get_quote_based_on_trade_direction(@chain_args[:middle],@chain_args[:middle_trade_direction])
      @trade_three_quote = get_quote_based_on_trade_direction(@chain_args[:ending],@chain_args[:ending_trade_direction])
      @trade_one_price = @trade_one_quote * 0.999
      @trade_two_price = @trade_two_quote * 0.999
      @trade_three_price = @trade_three_quote * 0.999
      @trade_one_price * @trade_two_price * @trade_three_price * FIAT_DECIMAL_INITIAL_AMOUNT
    end
    def to_s
      profit = @profit
      if START_CURRENCY == END_CURRENCY
        profit = @profit.to_s
      else
        profit = "Please Manually Calculate For Now"
      end
      return "#{@chain_args} - result: #{@result} - profit is = #{profit}"
    end
  end
  class ChainFactory
    def initialize(public_client,all_product_ids,all_products)
      @all_products = all_products
      @public_client = public_client
      @all_product_ids = all_product_ids
      puts "all product ids is"
      puts @all_product_ids
      @start_currency = CoinjarTriangleArbitrage::START_CURRENCY
      @end_currency = CoinjarTriangleArbitrage::END_CURRENCY
      @split_ids = @all_product_ids.map {|id| id.split("/")}
      @start_pairs = find_starting_pairs
      puts "split ids - #{@start_pairs}"
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
      puts "finding start pairs"
      puts "done finding start pairs"
      return @split_ids.select {|pair| @start_currency == pair[0] || @start_currency == pair[1]}
    end

    def find_intermediate_pairs
      puts "starting to find intermediate pairs"
      sieved_pairs = []
      start_symbols = @starting_trades
      start_symbols = start_symbols.flatten.filter {|symbol| symbol != @start_currency.to_s }
      end_symbols = start_symbols
      if @start_currency != @end_currency
        end_symbols = @end_pairs.flatten.filter {|symbol| symbol != @end_currency.to_s }
      end
      Parallel.each(start_symbols,in_threads:start_symbols.count) do |start|
        end_symbols.each do |ending|
          if @split_ids.any?([start,ending])
            sieved_pairs << [start,ending]
          end
          if @split_ids.any?([ending,start])
            sieved_pairs << [ending,start]
          end
        end
      end
      puts "done finding intermediate pairs"
      return sieved_pairs
    end

    def find_ending_pairs
      puts "finding ending pairs"
      @split_ids.select {|pair| @end_currency == pair[0] || @end_currency == pair[1]}
      puts "done finding ending pairs"
    end
    def determine_buy_or_sell(pair)
      if pair[1] == @start_currency
        return :buy
      elsif pair[0] == @end_currency
        return :buy
      else
        return :sell
      end
    end
    def determine_middle_buy_or_sell(start,middle)
      operative = start.filter{|symbol| symbol != @start_currency}
      if operative == middle[0]
        return :buy
      else
        return :sell
      end
    end
    def build_middle_pairs(start,ending)
      merged = start + ending
      merged.select {|symbol| symbol != @start_currency || symbol != @end_currency}
      return merged.select {|symbol| symbol != @start_currency || symbol != @end_currency}
    end
    def build_chains
      puts "building chains now"
      chains = []
      chain_args = {}
      Parallel.each(@starting_trades.uniq,in_threads:@starting_trades.uniq.count) do |start|
        @end_pairs.uniq.each do |ending|
          middle = build_middle_pairs(start,ending)
          if @split_ids.any? {|pair| pair == middle}
            chain_args = {start: start,:start_trade_direction => determine_buy_or_sell(start),middle:middle,:middle_trade_direction => determine_middle_buy_or_sell(middle,ending),ending:ending,:ending_trade_direction => determine_buy_or_sell(ending)}
            chain = Chain.new(@public_client,chain_args)
            puts chain.to_s
            chains.append(chain)
          else
            next
          end
        end
      end
      puts "done building chains"
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
      ChainFactory.new(@@public_client,@all_product_ids,@all_products).build_chains.max {|chain| chain.profit <=> chain.profit}
    end
  end
  class Trader

    def initialize(winning_chain)
      @trading = TRADING
      @winner = winning_chain
      @chain_args = @winner.chain_args
      @client = PrivateClient.new
      @public = PublicClient.new
    end
    def get_precision(product,order_side)
      all_products = @public.get_all_products
      selected_product = all_products.select {|p| p["name"] == product.join("/")}
      # selected_product = selected_product[0]
      puts selected_product.to_s
      if order_side == :buy
        precision = selected_product[0]["counter_currency"]
        puts precision
        return precision["subunit_to_unit"].to_i.digits[1..-1].length
      else
        precision = selected_product[0]["base_currency"]
        puts precision
        return precision["subunit_to_unit"].to_i.digits[1..-1].length
      end
    end
    def wait_until_filled(oid)
      order = @client.get_order(oid)
      if order == {}
        raise "response is empty"
      end
      puts order
      while order["status"] != "filled" 
        sleep 1
        puts order.to_s
      end
    end
    def run
      while @trading
        if @winner.profit >= MIN_PROFIT
          amount_one = FIAT_DECIMAL_INITIAL_AMOUNT.to_f * @winner.get_quote_based_on_trade_direction(@chain_args[:start],@chain_args[:start_trade_direction]).to_f
          amount_one = amount_one.truncate(get_precision(@chain_args[:start],@chain_args[:start_trade_direction])).to_s
          trade_one = @client.place_order(@chain_args[:start],@winner.trade_one_price,@chain_args[:start_trade_direction].to_s,amount_one)
          puts trade_one
          wait_until_filled(trade_one["oid"])
          amount_two = trade_one["size"].to_f * @winner.get_quote_based_on_trade_direction(@chain_args[:middle],@chain_args[:middle_trade_direction]).to_f
          amount_two = amount_two.truncate(get_precision(@chain_args[:middle],@chain_args[:middle_trade_direction])).to_s
          trade_two = @client.place_order(@chain_args[:middle],@winner.trade_two_price,@chain_args[:middle_trade_direction].to_s,amount_two)
          puts trade_two
          wait_until_filled(trade_two["oid"])
          amount_three = trade_two["size"].to_f * @winner.get_quote_based_on_trade_direction(@chain_args[:ending],@chain_args[:ending_trade_direction]).to_f
          amount_three = amount_three.truncate(get_precision(@chain_args[:ending],@chain_args[:ending_trade_direction])).to_s
          trade_three = @client.place_order(@chain_args[:ending],@winner.trade_three_price,@chain_args[:ending_trade_direction].to_s,amount_three)
          puts trade_three
          wait_until_filled(trade_three["oid"])
        end
      end
    end
  end
end


winner = CoinjarTriangleArbitrage::Scout.new.run
puts winner.to_s
CoinjarTriangleArbitrage::Trader.new(winner).run