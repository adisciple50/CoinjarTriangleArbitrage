# frozen_string_literal: true

require_relative "CoinjarTriangleArbitrage/version"
require 'httparty'
require 'json'
require 'parallel'
require 'logger'



module CoinjarTriangleArbitrage
  START_CURRENCY = 'GBP'
  END_CURRENCY = 'GBP'
  FIAT_DECIMAL_INITIAL_AMOUNT = 200.00
  TRADING = false
  MIN_PROFIT = 0.02
  COMMISION = 0.999
  LOG = Logger.new('trades.log')
  class PublicClient
    include HTTParty
    headers {'accept' => 'application/json'}
    def initialize
    end
    def get_all_products
      begin
      request = self.class.get('https://api.exchange.coinjar.com/products',format: :json)
      response = request.body.to_s
      # puts "all products response is #{response}"
      JSON.parse(response)
      rescue
        LOG.debug "error in response from method all products found"
        LOG.debug response
      end
    end
    def ticker(id)
      id = id.to_s.upcase
      request = self.class.get("https://data.exchange.coinjar.com/products/#{id}/ticker",format: :plain)
      response = request.body.to_s
      # puts "ticker response is #{response} and id is #{id}"
      JSON.parse(response)
    end
    def get_precision(product,order_side)
      all_products = get_all_products
      selected_product = all_products.select {|p| p["name"] == product.join("/")}
      if order_side == :buy
        precision = selected_product[0]["counter_currency"]
        # puts precision
        x = precision["subunit_to_unit"].to_i.digits[1..-1].length
        # puts x
        return x
      else
        precision = selected_product[0]["base_currency"]
        # puts precision
        x = precision["subunit_to_unit"].to_i.digits[1..-1].length
        # puts x
        return x
      end
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
    attr_accessor :result,:chain_args,:trade_one_quote,:trade_two_quote,:trade_three_quote,:trade_one_amount,:trade_two_amount,:trade_three_amount,:profit,:trade_one_price,:trade_two_price,:trade_three_price
    def initialize(public_client,chain_args)
      @public_client = public_client
      @chain_args = chain_args
      @result = calculate_result
      # only valid if the start currency and end currency are the same
      @profit = @result - FIAT_DECIMAL_INITIAL_AMOUNT
    end
    #BTC/GBP - BTC base - GBP pair
    def pair_to_base(base,pair)
      1 / @public_client.ticker("#{base}#{pair}")["ask"].to_f * 1
    end
    def base_to_pair(base,pair)
      @public_client.ticker("#{base}#{pair}")["ask"].to_f
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
      @ticker_one = @public_client.ticker("#{@chain_args[:start][0]}#{@chain_args[:start][1]}")["ask"].to_f
      @ticker_two = @public_client.ticker("#{@chain_args[:middle][0]}#{@chain_args[:middle][1]}")["ask"].to_f
      @ticker_three = @public_client.ticker("#{@chain_args[:ending][0]}#{@chain_args[:ending][1]}")["ask"].to_f
      @trade_one_quote = get_quote_based_on_trade_direction(@chain_args[:start],@chain_args[:start_trade_direction])
      @trade_two_quote = get_quote_based_on_trade_direction(@chain_args[:middle],@chain_args[:middle_trade_direction])
      @trade_three_quote = get_quote_based_on_trade_direction(@chain_args[:ending],@chain_args[:ending_trade_direction])
      @trade_one_amount = FIAT_DECIMAL_INITIAL_AMOUNT * @trade_one_quote * COMMISION
      @trade_one_amount.truncate(@public_client.get_precision(@chain_args[:start],@chain_args[:start_trade_direction]))
      @trade_two_amount = @trade_one_amount * COMMISION * @trade_two_quote
      @trade_two_amount.truncate(@public_client.get_precision(@chain_args[:middle],@chain_args[:middle_trade_direction]))
      @trade_three_amount = @trade_two_amount * COMMISION * @trade_three_quote
      @trade_three_amount.truncate(@public_client.get_precision(@chain_args[:ending],@chain_args[:ending_trade_direction]))
      @trade_one_price = @ticker_one
      @trade_two_price = @ticker_two
      @trade_three_price = @ticker_three
      @result = @trade_three_amount
    end
    def to_s
      profit = @profit
      if START_CURRENCY == END_CURRENCY
        profit = @profit.to_s
      else
        profit = "Please Manually Calculate For Now"
      end
      @chain_args[:trade_one_price] = @trade_one_price
      @chain_args[:trade_two_price] = @trade_two_price
      @chain_args[:trade_three_price] = @trade_three_price
      @chain_args[:trade_one_amount] = @trade_one_amount
      @chain_args[:trade_two_amount] = @trade_two_amount
      @chain_args[:trade_three_amount] = @trade_three_amount

      return "#{@chain_args} - result: #{@result} - profit is = #{profit}"
    end
    def to_h
      profit = @profit
      if START_CURRENCY == END_CURRENCY
        profit = @profit.to_s
      else
        profit = "Please Manually Calculate For Now"
      end
      @chain_args[:trade_one_price] = @trade_one_price
      @chain_args[:trade_two_price] = @trade_two_price
      @chain_args[:trade_three_price] = @trade_three_price
      @chain_args[:trade_one_amount] = @trade_one_amount
      @chain_args[:trade_two_amount] = @trade_two_amount
      @chain_args[:trade_three_amount] = @trade_three_amount

      return @chain_args.update({result: @result}).update({profit: profit})
    end
  end
  class ChainFactory
    def initialize(public_client,all_product_ids,all_products)
      @all_products = all_products
      @public_client = public_client
      @all_product_ids = all_product_ids
      # puts "all product ids is"
      # puts @all_product_ids
      @start_currency = CoinjarTriangleArbitrage::START_CURRENCY
      @end_currency = CoinjarTriangleArbitrage::END_CURRENCY
      @split_ids = @all_product_ids.map {|id| id.split("/")}
      @start_pairs = find_starting_pairs
      # puts "split ids - #{@start_pairs}"
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
      LOG.info "finding start pairs"
      LOG.info "done finding start pairs"
      puts "finding start pairs"
      puts "done finding start pairs"
      return @split_ids.select {|pair| @start_currency == pair[0] || @start_currency == pair[1]}
    end

    def find_intermediate_pairs
      LOG.info "starting to find intermediate pairs"
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
      LOG.info "done finding intermediate pairs"
      puts "done finding intermediate pairs"
      return sieved_pairs
    end

    def find_ending_pairs
      LOG.info "finding ending pairs"
      puts "finding ending pairs"
      @split_ids.select {|pair| @end_currency == pair[0] || @end_currency == pair[1]}
      LOG.info "done finding ending pairs"
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
      LOG.info "building chains now"
      puts "building chains now"
      chains = []
      chain_args = {}
      Parallel.each(@starting_trades.uniq,in_threads:@starting_trades.uniq.count) do |start|
        @end_pairs.uniq.each do |ending|
          middle = build_middle_pairs(start,ending)
          if @split_ids.any? {|pair| pair == middle}
            chain_args = {start: start,:start_trade_direction => determine_buy_or_sell(start),middle:middle,:middle_trade_direction => determine_middle_buy_or_sell(middle,ending),ending:ending,:ending_trade_direction => determine_buy_or_sell(ending)}
            chain = Chain.new(@public_client,chain_args)
            if chain.profit.nan?
              next
            end
            # puts chain.to_h.to_s
            chains.append(chain)
          else
            next
          end
        end
      end
      LOG.info "done building chains"
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
      @public.get_precision(product,order_side)
    end
    def wait_until_filled(oid)
      order = @client.get_order(oid)
      if order == {}
        raise "response is empty"
      end
      LOG.info order
      puts order
      while order["status"] != "filled"
        sleep 1
        LOG.info "response is"
        puts "response is"
        puts order.to_s
      end
    end
    def run
      while @trading
        if @winner.profit >= MIN_PROFIT
          amount_one = @winner.trade_one_amount
          amount_one = amount_one.truncate(get_precision(@chain_args[:start],@chain_args[:start_trade_direction])).to_s
          LOG.info "amount 1 is"
          LOG.info amount_one
          puts "amount 1 is"
          puts amount_one
          trade_one = @client.place_order(@chain_args[:start].join,@winner.trade_one_price,@chain_args[:start_trade_direction].to_s,amount_one)
          LOG.info "trade_one is"
          LOG.info trade_one
          puts "trade_one is"
          puts trade_one
          wait_until_filled(trade_one["oid"])
          amount_two = @winner.trade_two_amount
          amount_two = amount_two.truncate(get_precision(@chain_args[:middle],@chain_args[:middle_trade_direction])).to_s
          trade_two = @client.place_order(@chain_args[:middle].join,@winner.trade_two_price,@chain_args[:middle_trade_direction].to_s,amount_two)
          LOG.info trade_two
          puts trade_two
          wait_until_filled(trade_two["oid"])
          amount_three = @winner.trade_three_amount
          amount_three = amount_three.truncate(get_precision(@chain_args[:ending],@chain_args[:ending_trade_direction])).to_s
          trade_three = @client.place_order(@chain_args[:ending].join,@winner.trade_three_price,@chain_args[:ending_trade_direction].to_s,amount_three)
          LOG.info trade_three
          puts trade_three
          wait_until_filled(trade_three["oid"])
        end
      end
    end
  end
end
won = false
while CoinjarTriangleArbitrage::TRADING || !won
  winner = CoinjarTriangleArbitrage::Scout.new.run
  if winner.profit > 0
    won = true
    CoinjarTriangleArbitrage::LOG.info "INITIAL STAKE"
    CoinjarTriangleArbitrage::LOG.info CoinjarTriangleArbitrage::FIAT_DECIMAL_INITIAL_AMOUNT
    CoinjarTriangleArbitrage::LOG.info "_______TRADE 1"
    CoinjarTriangleArbitrage::LOG.info "TRADE 1 INSTRUMENT"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:start].join("/")
    CoinjarTriangleArbitrage::LOG.info "TRADE 1 PRICE"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:trade_one_price]
    CoinjarTriangleArbitrage::LOG.info "TRADE 1 DIRECTION"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:start_trade_direction]
    CoinjarTriangleArbitrage::LOG.info "TRADE 1 AMOUNT"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:trade_one_amount]
    CoinjarTriangleArbitrage::LOG.info "_______TRADE 2"
    CoinjarTriangleArbitrage::LOG.info "TRADE 2 INSTRUMENT"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:middle].join("/")
    CoinjarTriangleArbitrage::LOG.info "TRADE 2 PRICE"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:trade_two_price]
    CoinjarTriangleArbitrage::LOG.info "TRADE 2 DIRECTION"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:middle_trade_direction]
    CoinjarTriangleArbitrage::LOG.info "TRADE 2 AMOUNT"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:trade_two_amount]
    CoinjarTriangleArbitrage::LOG.info "_______TRADE 3"
    CoinjarTriangleArbitrage::LOG.info "TRADE 3 INSTRUMENT"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:ending].join("/")
    CoinjarTriangleArbitrage::LOG.info "TRADE 3 PRICE"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:trade_three_price]
    CoinjarTriangleArbitrage::LOG.info "TRADE 3 DIRECTION"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:ending_trade_direction]
    CoinjarTriangleArbitrage::LOG.info "TRADE 3 AMOUNT"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:trade_three_amount]
    CoinjarTriangleArbitrage::LOG.info "_______Arb Result"
    CoinjarTriangleArbitrage::LOG.info "RESULT"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:result]
    CoinjarTriangleArbitrage::LOG.info "PROFIT"
    CoinjarTriangleArbitrage::LOG.info winner.to_h[:profit]
    CoinjarTriangleArbitrage::LOG.info "MARKUP PERCENTAGE - more than 100 percent to break even"
    markup = (winner.to_h[:result].to_f / CoinjarTriangleArbitrage::FIAT_DECIMAL_INITIAL_AMOUNT) * 100
    CoinjarTriangleArbitrage::LOG.info markup.to_s.join("%")

    # print to terminal

    puts "INITIAL STAKE"
    puts CoinjarTriangleArbitrage::FIAT_DECIMAL_INITIAL_AMOUNT
    puts "_______TRADE 1"
    puts "TRADE 1 INSTRUMENT"
    puts winner.to_h[:start].join("/")
    puts "TRADE 1 PRICE"
    puts winner.to_h[:trade_one_price]
    puts "TRADE 1 DIRECTION"
    puts winner.to_h[:start_trade_direction]
    puts "TRADE 1 AMOUNT"
    puts winner.to_h[:trade_one_amount]
    puts "_______TRADE 2"
    puts "TRADE 2 INSTRUMENT"
    puts winner.to_h[:middle].join("/")
    puts "TRADE 2 PRICE"
    puts winner.to_h[:trade_two_price]
    puts "TRADE 2 DIRECTION"
    puts winner.to_h[:middle_trade_direction]
    puts "TRADE 2 AMOUNT"
    puts winner.to_h[:trade_two_amount]
    puts "_______TRADE 3"
    puts "TRADE 3 INSTRUMENT"
    puts winner.to_h[:ending].join("/")
    puts "TRADE 3 PRICE"
    puts winner.to_h[:trade_three_price]
    puts "TRADE 3 DIRECTION"
    puts winner.to_h[:ending_trade_direction]
    puts "TRADE 3 AMOUNT"
    puts winner.to_h[:trade_three_amount]
    puts "_______Arb Result"
    puts "RESULT"
    puts winner.to_h[:result]
    puts "PROFIT"
    puts winner.to_h[:profit]
    puts "MARKUP PERCENTAGE - 100 percent to break even"
    puts markup.to_s.join("%")
    
    
    CoinjarTriangleArbitrage::Trader.new(winner).run
  end
end