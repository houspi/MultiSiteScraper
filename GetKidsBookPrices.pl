#!/usr/bin/perl -w
#
# GetKidsBookPrices.pl
# SCRAPING SCRIPT FOR WEBSITES
# https://www.barnesandnoble.com
# https://www.amazon.com
# https://www.target.com
# https://www.christianbook.com
# https://www.booksellerusa.com
# 
# By houspi@gmail.com
#  1.0.0/30.07.2018 
#  1.0.1/01.08.2018 
#
# command line options [-s SleepTimeout] [ -q ISBN-13] [-h]
#  -h     display this help and exit.
#  -s     set the Sleep Timeout between requests. 10 seconds by default.
#  -p     use proxy
#  -q     check the code of one book
#
# Out
#       books_prices.txt    - books prices
#
# On restart books from the books_prices.txt file are skipped
# Delete it to start from scratch
#
# CHANGES
#-----------------------
# 1.0.1 fixed bug with searching in the bookseller;
#       fixed bug with bad json format.
#
use strict;
use threads;
use threads::shared;
use Getopt::Std;
use WWW::Mechanize;
use HTTP::Cookies;
use HTML::TreeBuilder;
use utf8;
use Encode;
use HTML::FormatText;
use Data::Dumper;
use FileHandle;
use Time::HiRes qw(gettimeofday);
use JSON;

my $DEBUG     = 1;
my $MaxRetry  = 5;
my $MaxSleep  = 10;
my $MaxImages = 3;
my $BooksPrices = "books_prices.txt";
my $USE_PROXY = 0;
my $PROXY_HOST = "";
my $PROXY_PORT ="";

my @fields = qw /
    ISBN13
    BookName
    Format
    Writers
    OriginalPrice
    SalePrice
    FinalPrice
    Image1
    Image2
    Image3
    Publisher
    Year
    Series
    Edition
    Pages
    Dimension
    Overview
    AboutAuthor
    AmazonPrice
    AmazonFinalPrice
    AmazonQty
    TargetPrice
    TargetFinalPrice
    TargetQty
    BooksellerPrice
    BooksellerFinalPrice
    BooksellerDetails
    RainbowPrice
    RainbowFinalPrice
    ChristianPrice
    ChristianFinalPrice
    BestFinalPrice
    BestSellerPrice
    BestFinalQty
/;
my $BestFinalPrice  = 0;
my $BestSellerPrice = "";
my $BestFinalQty    = 0;

my @KeysOrder = ('Amazon', 'Target', 'Booksellerusa', 'Rainbowresource', 'Christianbook', );
my %OtherPrices = (
    'Amazon'          => 'https://www.amazon.com/s/ref=nb_sb_noss?url=search-alias%3Dstripbooks&field-keywords=',
    'Booksellerusa'   => 'https://www.searchanise.com/getresults?api_key=9H7I8o7T5L&sortBy=relevance&sortOrder=desc&startIndex=0&maxResults=15&items=true&pages=true&categories=true&suggestions=true&queryCorrection=true&suggestionsMaxResults=3&pageStartIndex=0&pagesMaxResults=20&categoryStartIndex=0&categoriesMaxResults=20&facets=true&facetsShowUnavailableOptions=true&ResultsTitleStrings=2&ResultsDescriptionStrings=2&output=jsonp&q=',
    'Christianbook'   => 'https://www.christianbook.com/Christian/Books/easy_find?N=1014644&Ntk=keywords&action=Search&Ne=0&event=ESRCN&nav_search=1&cms=1&Ntt=',
    'Rainbowresource' => 'https://www.rainbowresource.com/searchspring/?q=',
    'Target'          => 'https://redsky.target.com/v1/plp/search/?count=24&offset=0&keyword=',
);

my %PricesCallBack = (
    'Amazon'          => \&GetFromAmazon,
    'Booksellerusa'   => \&GetFromBooksellerusa,
    'Christianbook'   => \&GetFromChristianbook,
    'Rainbowresource' => \&GetFromRainbowresource,
    'Target'          => \&GetFromTarget,
);


my $BaseUrl     = 'https://www.barnesandnoble.com';
my @SearchPath = ('/b/books/kids/_/N-7Z1fZ29Z8q8Ztu1?Ns=P_Sales_Rank',  '/b/books/kids/_/N-8Z1fZ29Z8q8Ztu1?Ns=P_Sales_Rank');

my %BarnesAndNobleAges = (
'0-2 years' => 'https://www.barnesandnoble.com/b/books/kids/_/N-7Z8q8Ztu1?Ns=P_Sales_Rank&Nrpp=40',
'3-5 years' => 'https://www.barnesandnoble.com/b/books/kids/_/N-8Z8q8Ztu1?Ns=P_Sales_Rank&Nrpp=40',
);

# Parsing command line options
my %opts;
getopts('hs:p:q:', \%opts);
if ($opts{'h'}) {
    Usage($0);
        exit(0);
}

if ($opts{'s'}) {
    $MaxSleep = $opts{'s'};
    $MaxSleep =~ s/\D//g;
    $MaxSleep = 0 if (!$MaxSleep);
}

if ($opts{'p'}) {
    ($PROXY_HOST, $PROXY_PORT ) = split(/:/, $opts{'p'}, 2);
    $USE_PROXY = 1;
    print_debug(2, "set proxy $PROXY_HOST, $PROXY_PORT\n");
}

my $QuickCheck = 0;
if ($opts{'q'}) {
    $QuickCheck = $opts{'q'};
}

# Read scraped books
my %BooksDone = ();
if (open(BD, $BooksPrices)) {
    while(<BD>) {
        chomp;
        my ($isbn, $tail) = split "\t", $_, 2;
        $BooksDone{$isbn} = 1;
    }
}

# Print headers to ouptul file
unless ( -e $BooksPrices ) {
    open OUTDAT,">>", $BooksPrices;
    print OUTDAT join("\t", @fields), "\n";
    close OUTDAT;
}

my $mech;
{
	local $^W = 0;
	$mech = WWW::Mechanize->new( autocheck => 1, ssl_opts => {verify_hostname => 0,SSL_verify_mode => 0} );
}
$mech->timeout(30);
$mech->default_header('User-Agent'=>'Mozilla/5.0 (Windows NT 5.1; rv:11.0) Gecko/20100101 Firefox/11.0');
$mech->default_header('Accept'=>'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
$mech->default_header('Accept-Language'=>'en');
$mech->default_header('Accept-Encoding'=>'gzip, deflate');
$mech->default_header('Connection'=>'keep-alive');
$mech->default_header('Pragma'=>'no-cache');
$mech->default_header('Cache-Control'=>'no-cache');
$mech->proxy(['http', 'https'], "http://$PROXY_HOST:$PROXY_PORT") if $USE_PROXY;

print_debug(1, "Start scraping $BaseUrl\n");

if ( $QuickCheck ) {
    QuickCheck($mech, $QuickCheck ); 
    exit(0);
}

sub QuickCheck {
    my $mech     = shift;
    my $isbn13   = shift;

    $DEBUG = 2;
#    $isbn13 = "9780694003617";
    print_debug(1, "Quick check $isbn13\n");
    my @BookInfo = ();
    GetFromAmazon($mech, $isbn13, \@BookInfo);
    print join( "\n", @BookInfo), "\n";
    @BookInfo = ();
    GetFromTarget($mech, $isbn13, \@BookInfo);
    print join( "\n", @BookInfo), "\n";
    @BookInfo = ();
    GetFromBooksellerusa($mech, $isbn13, \@BookInfo);
    print join( "\n", @BookInfo), "\n";
    @BookInfo = ();
    GetFromChristianbook($mech, $isbn13, \@BookInfo); 
    print join( "\n", @BookInfo), "\n";
}

my ($RetCode, $Errm) = &ReTry($BaseUrl, $mech, $MaxRetry, $MaxSleep);

foreach ( sort keys %BarnesAndNobleAges ) {
    print_debug(1, "Ages $_ ... \n");
    ProcessBarnesandnoble($mech, $BarnesAndNobleAges{$_});
}

=head1 ProcessBarnesandnoble
get list from https://www.barnesandnoble.com
mech
Path
=cut
sub ProcessBarnesandnoble {
    my $mech = shift;
    my $Path = shift;
    
    my $PageUrl = $Path;
    my $Page = 1;
    
    my $ListMech = $mech->clone();
    $ListMech->proxy(['http', 'https'], "http://$PROXY_HOST:$PROXY_PORT") if $USE_PROXY;
    do {
        my ($RetCode, $Errm) = &ReTry($PageUrl, $ListMech, $MaxRetry, $MaxSleep);
        my $content = $ListMech->content(decoded_by_headers => 1);
        my $ListPage  = HTML::TreeBuilder->new();
        $ListPage->ignore_unknown(1);
        $ListPage->parse_content(decode_utf8($content));
        my $pagination = $ListPage->look_down(_tag => 'ul', 'class' => 'pagination search-pagination');
        my $Pages = 1;
        if ($pagination) {
            my @a = $pagination->look_down(_tag => 'a');
            $Pages = $a[-2]->as_trimmed_text(extra_chars => '\xA0');
            $Pages =~ s/\D//g;
        }
        print_debug(1, "Page $Page of $Pages \n");
        my $json;
        $content =~ /var digitalData = (.+?);\n/;
        eval {  $json = decode_json($1) };
        if ($@) {
            print_debug(1, "Bad data returned:", $@, "\n");
            print_debug(1, "====\n");
            print_debug(1, $content);
            last;
        }
        foreach (@{$json->{'product'}}) {
            print_debug(3, "ISBN ", $_->{'productInfo'}->{'sku'}, "\n");
            next if ( exists($BooksDone{$_->{'productInfo'}->{'sku'}} ) );
            #print "ISBN ", $_->{'productInfo'}->{'sku'}, "\n";
            #print "Name ", $_->{'productInfo'}->{'productName'}, "\n";
            #print "URL ", $_->{'productInfo'}->{'productURL'}, "\n";
            my @BookInfo = ();
            GetFromBarnesandnoble($ListMech, $BaseUrl . $_->{'productInfo'}->{'productURL'}, \@BookInfo);
            #exit(5);
        }

        my $next = $ListPage->look_down(_tag => 'a', class => 'next-button');
        if ($next && $next->attr('aria-disabled')) {
            $PageUrl = "";
        } else {
            $PageUrl = $next->attr('href');
        }
        print_debug(2, "Next Page $PageUrl\n");
        $Page++;
#        exit(1);
        
    } while ($PageUrl);
}

=head1 GetFromBarnesandnoble
get book's info from https://www.barnesandnoble.com
mech
Path
=cut
sub GetFromBarnesandnoble {
    my $mech = shift;
    my $Path = shift;
    my $BookInfo = shift;
    
    my $PageUrl = $Path;
    my $isbn13 = "";
    
    my $current_price;

    my $DetMech = $mech->clone();
    $DetMech->proxy(['http', 'https'], "http://$PROXY_HOST:$PROXY_PORT") if $USE_PROXY;
    &ReTry($PageUrl, $DetMech, $MaxRetry, 1);
    my $DetPage  = HTML::TreeBuilder->new();
    my $content = $DetMech->content(decoded_by_headers => 1);
    $DetPage->ignore_unknown(1);
    $DetPage->parse_content(decode_utf8($content));
    # All data contains in the JSON format
    # Lookin for it.
    if ($content =~ /var digitalData = (.+?);\n/) {
        my $json = decode_json($1);
#        print Dumper($json);
#        exit(3);
        $isbn13 = $json->{'product'}->[0]->{'productInfo'}->{'sku'};
        print_debug(1, "isbn13", $isbn13 , "\n");
        # ISBN-13
        push(@{$BookInfo}, $isbn13);

        #BookName
        push(@{$BookInfo}, $json->{'product'}->[0]->{'productInfo'}->{'productName'});

        #Format
        # <h2 id="pdp-info-format" class="h2-as-h6" itemprop="bookFormat">NOOK Book<span class="editionFormat pl-xxs">(NOOK Kids Read to Me)</span>
        #<h2 id="pdp-info-format" itemprop="bookFormat" class="h2-as-h6 commerce-zone-format">Board Book</h2
        my $tag = $DetPage->look_down(_tag => 'h2', 'id' => 'pdp-info-format');
        push(@{$BookInfo}, $tag->as_trimmed_text(extra_chars => '\xA0'));

        #Author
        $tag = $DetPage->look_down(_tag => 'span', 'itemprop' => 'author');
        push(@{$BookInfo}, $tag->as_trimmed_text(extra_chars => '\xA0'));
        
        # Prices
        # OriginalPrice
        #<s class="old-price">$5.99</s>
        my $OriginalPrice = 0;
        $tag = $DetPage->look_down(_tag => 's', 'class' => 'old-price');
        if ($tag) {
            $OriginalPrice = $tag->as_trimmed_text(extra_chars => '\xA0');
            $OriginalPrice =~ s/\$//;
        }

        # SalePrice
        #<span id="pdp-cur-price" class="price current-price ml-0"><sup>$</sup>4.52</span>
        my $SalePrice = 0;
        $tag = $DetPage->look_down(_tag => 'span', 'id' => 'pdp-cur-price');
        if($tag) {
            $SalePrice = $tag->as_trimmed_text(extra_chars => '\xA0');
            $SalePrice =~ s/\$//;
        }

        $OriginalPrice = $SalePrice if(!$OriginalPrice);
        push(@{$BookInfo}, $OriginalPrice);
        push(@{$BookInfo}, $SalePrice);

        # FinalPrice
        my $FinalPrice = sprintf( '%.2f', $SalePrice*0.837);
        push(@{$BookInfo}, $FinalPrice );

        #BestFinalPrice
        $BestFinalPrice = $FinalPrice;
        $BestSellerPrice = 'BarnesAndNoble';
        $BestFinalQty = 0;
        
        # Images;
        my $imgCount = 0;
        foreach ( $DetPage->look_down(_tag => 'div', 'class' => 'product-shelf-image') ) {
            $imgCount++;
            my $a = $_->look_down(_tag =>'a');
            my $img_domain = $a->attr('data-liquiddomain');
            my $img = $_->look_down(_tag =>'img');
            my $src = $img->attr('src');
            push(@{$BookInfo}, 'https:' . $src);
            last if($imgCount == $MaxImages);
        }
        while( $imgCount < $MaxImages ) {
            push(@{$BookInfo}, 'NoImage');
            $imgCount++;
        }

        # ProductDetailsTab
        $tag = $DetPage->look_down(_tag => 'div', 'id' => 'ProductDetailsTab');
        my %productDetails = ();
        foreach ( $tag->look_down(_tag=>'table')->look_down(_tag => 'tr') ) {
            $productDetails{$_->look_down(_tag => 'th')->as_trimmed_text(extra_chars => '\xA0')} = $_->look_down(_tag => 'td')->as_trimmed_text(extra_chars => '\xA0');
        }

        # Publisher
        if ( exists($productDetails{'Publisher:'}) ) {
            push(@{$BookInfo}, $productDetails{'Publisher:'});
        } else {
            push(@{$BookInfo}, '');
        }

        # Year
        if ( exists($productDetails{'Publication date:'}) ) {
            if ( $productDetails{'Publication date:'} =~ /\/(\d{4})$/ ) {
                push(@{$BookInfo}, $1 );
            } else {
                push(@{$BookInfo}, '' );
            }
        } else {
            push(@{$BookInfo}, '');
        }

        # Series
        if ( exists($productDetails{'Series:'}) ) {
            push(@{$BookInfo}, $productDetails{'Series:'});
        } else {
            push(@{$BookInfo}, '');
        }

        # Edition
        if ( exists($productDetails{'Edition description:'}) ) {
            push(@{$BookInfo}, $productDetails{'Edition description:'});
        } else {
            push(@{$BookInfo}, '');
        }

        # Pages
        if ( exists($productDetails{'Pages:'}) ) {
            push(@{$BookInfo}, $productDetails{'Pages:'});
        } else {
            push(@{$BookInfo}, '');
        }

        # Dimension
        if ( exists($productDetails{'Product dimensions:'}) ) {
            push(@{$BookInfo}, $productDetails{'Product dimensions:'});
        } else {
            push(@{$BookInfo}, '');
        }

        # Overview
        $tag = $DetPage->look_down(_tag => 'div', 'id' => 'productInfoOverview');
        if ( $tag && $tag->look_down(_tag => 'p', 'class' => "text--medium ") ) {
            my $overview = $DetPage->look_down(_tag => 'div', 'id' => 'productInfoOverview')->as_HTML();
            $overview =~ s/<h2 .+?h2>|<div class.+?div>|<.+?>|\n//g;
            $overview =~ s/'/\\'/g;
            push(@{$BookInfo}, "'" . $overview . "'");
        } else {
            push(@{$BookInfo}, '');
        }

        # AboutAuthor
        $tag = $DetPage->look_down(_tag => 'div', 'id' => 'MeetTheAuthor');
        if ($tag && $tag->look_down(_tag => 'div', 'class' => qr/text--medium /)) {
            my $MeetTheAuthor = $tag->look_down(_tag => 'div', 'class' => qr/text--medium /)->as_trimmed_text(extra_chars => '\xA0');
            $MeetTheAuthor =~ s/\n//g;
            $MeetTheAuthor =~ s/'/\\'/g;
            push(@{$BookInfo}, "'" . $MeetTheAuthor . "'");
        } else {
            push(@{$BookInfo}, '');
        }
        $isbn13 = $json->{'product'}->[0]->{'productInfo'}->{'sku'};
        #$isbn13 = "9780694003617";
        #GetFromAmazon($mech, $isbn13, $BookInfo);

        foreach my $SearchSite ( @KeysOrder ) {
            $PricesCallBack{$SearchSite}->($mech, $isbn13, $BookInfo);
        }

        push(@{$BookInfo}, $BestFinalPrice, $BestSellerPrice, $BestFinalQty);
        printInfo($BookInfo);
    } else {
        #print "NOT FOUND!!!\n";
        #print $content;
    }
    
}

sub printInfo {
    my $BookInfo = shift;
    my $i=0;
#    foreach (@fields) {
#        print $_, ":", $BookInfo->[$i], "\n";
#        $i++;
#    }
    open OUTDAT, ">>", $BooksPrices;
    binmode(OUTDAT, ":utf8");
    OUTDAT->autoflush(1);
    print OUTDAT join("\t", @{$BookInfo});
    print OUTDAT "\n";
    close(OUTDAT);
}

=head1 GetFromAmazon
get book's price from Amazon
mech
ISBN-13
Array With Data
=cut
sub GetFromAmazon {
    my $mech     = shift;
    my $isbn13   = shift;
    my $BookInfo = shift;

    print_debug(2, "GET Amazon\n");
    my $BMech = $mech->clone();
    my $price = "-";

    # Doing a search
    &ReTry($OtherPrices{'Amazon'} . $isbn13 , $BMech, $MaxRetry, 1);
    my $Page  = HTML::TreeBuilder->new();
    $Page->ignore_unknown(0);
    $Page->parse_content(decode_utf8($BMech->content(decoded_by_headers => 1)));
    my $a = $Page->look_down(_tag=>'a', 'class'=>'a-link-normal s-access-detail-page  s-color-twister-title-link a-text-normal');
    # Found
    if($a) {
        print_debug(3, "HREF ", $a->attr('href'), "\n");
        # <span class="a-size-medium a-color-price offer-price a-text-normal">$6.19</span>
        &ReTry($a->attr('href') , $BMech, $MaxRetry, 1);
        $Page->ignore_unknown(1);
        $Page->parse_content(decode_utf8($BMech->content(decoded_by_headers => 1)));
        my $tag;
        # Price
        $tag = $Page->look_down(_tag => 'span', 'class' => 'a-size-medium a-color-price offer-price a-text-normal');
        if ($tag) {
            $price = $tag->as_trimmed_text(extra_chars => '\xA0');
            $price =~ s/\$//;
            print_debug(3, "price",  $price, "\n");
            push(@{$BookInfo}, $price);
            my $FinalPrice = sprintf( '%.2f', $price*0.97);
            push(@{$BookInfo}, $FinalPrice );
            # Qty
            #  <form method="post" id="addToCart" action="/gp/product/handle-buy-box/ref=dp_start-bbf_1_glance" class="a-content">
            # <select name="quantity" autocomplete="off" 
            my $qty = 1;
            if ( $BMech->form_id("addToCart")->find_input('quantity') ) {
                my @qty = $BMech->form_id("addToCart")->find_input('quantity')->possible_values;
                #print_debug(2, "Qty values", @qty, "\n");
                # print_debug(2, "Qty ", $qty[$#qty-1], "\n");
                $qty = $qty[$#qty -1 ];
            }
            push(@{$BookInfo}, $qty);
            if ($FinalPrice < $BestFinalPrice ) {
                $BestFinalPrice = $FinalPrice;
                $BestSellerPrice = 'Amazon';
            }
            $BestFinalQty = $qty if ($qty > $BestFinalQty);
        } else {
        print_debug(2, "Empty",  ,"\n");
        push(@{$BookInfo}, '0', '0', '0');
        }
    } else {
        print_debug(2, "Empty",  ,"\n");
        push(@{$BookInfo}, '0', '0', '0');
    }
}

=head1 GetFromTarget
get book's price from Target
mech
ISBN-13
Array With Data
=cut
sub GetFromTarget {
    my $mech   = shift;
    my $isbn13 = shift;
    my $BookInfo = shift;

    print_debug(2, "GET Target\n");
    my $BMech = $mech->clone();
    $BMech->proxy(['http', 'https'], "http://$PROXY_HOST:$PROXY_PORT") if $USE_PROXY;
    # Doing a search
    &ReTry($OtherPrices{'Target'} . $isbn13 , $BMech, $MaxRetry, 1);
#    $Page->parse_content();
#    my $json = decode_json(decode_utf8($BMech->content(decoded_by_headers => 1)));
    my $json = decode_json($BMech->content(decoded_by_headers => 1));
    # print Dumper($json);
    if ( exists( $json->{'search_response'}->{'items'}->{'Item'}->[0]->{'tcin'} ) ) {
        # https://redsky.target.com/v2/pdp/tcin/
        #print "Get details\n";
        &ReTry('https://redsky.target.com/v2/pdp/tcin/' . $json->{'search_response'}->{'items'}->{'Item'}->[0]->{'tcin'} , $BMech, $MaxRetry, 1);
        $json = decode_json($BMech->content(decoded_by_headers => 1));
        # print Dumper($json);
        push(@{$BookInfo}, $json->{'product'}->{'price'}->{'offerPrice'}->{'price'});
        my $FinalPrice = sprintf( '%.2f', $json->{'product'}->{'price'}->{'offerPrice'}->{'price'} * 0.95);
        push(@{$BookInfo},  $FinalPrice);
        my $qty = $json->{'product'}->{'item'}->{'attributes'}->{'max_order_qty'};
        push(@{$BookInfo}, $qty);

        if ($FinalPrice <= $BestFinalPrice ) {
            $BestFinalPrice = $FinalPrice;
            $BestSellerPrice = 'Target';
        }
        $BestFinalQty = $qty if ($qty > $BestFinalQty);
    } else {
        print_debug(2, "Not found on Target\n");
        push(@{$BookInfo}, '0', '0', '0');
    }
}

=head1 GetFromBooksellerusa
get book's price from Booksellerusa
mech
ISBN-13
Array With Prices
=cut
sub GetFromBooksellerusa {
    my $mech   = shift;
    my $isbn13 = shift;
    my $BookInfo = shift;

    print_debug(2, "GET Booksellerusa\n");
    my $BMech = $mech->clone();
    &ReTry($OtherPrices{'Booksellerusa'} . $isbn13 , $BMech, $MaxRetry, 1);
    my $json = decode_json($BMech->content(decoded_by_headers => 1));
    #print Dumper($json);
    if( exists($json->{'items'}) && exists($json->{'items'}->[0]->{'price'}) && $json->{'items'}->[0]->{'product_code'} == $isbn13  ) {
        my $price = $json->{'items'}->[0]->{'price'};
        push(@{$BookInfo}, $price);
        my $FinalPrice = sprintf( '%.2f', $price * 0.98);
        push(@{$BookInfo}, $FinalPrice);
        if ($FinalPrice <= $BestFinalPrice ) {
            $BestFinalPrice = $FinalPrice;
            $BestSellerPrice = 'BooksellerUSA';
        }
        &ReTry($json->{'items'}->[0]->{'link'} , $BMech, $MaxRetry, 1);
        my $Page  = HTML::TreeBuilder->new();
        $Page->ignore_unknown(0);
        my $content = decode_utf8($BMech->content(decoded_by_headers => 1));
        if ($content =~ /<div class="product-description rte".+?>(.+?)<\/div>/s) {
            my $ProductDescription = trim($1);
            $ProductDescription =~ s/<.+?>|\n//g;
            $ProductDescription =~ s/'/\\'/g;
            push(@{$BookInfo}, "'" . $ProductDescription . "'");
        } else {
            push(@{$BookInfo}, '');
        }
    } else {
        push(@{$BookInfo}, '0', '0', '');
    }
}

=head1 GetFromRainbowresource
get book's price from Rainbowresource
mech
ISBN-13
Array With Prices
=cut
sub GetFromRainbowresource {
    my $mech   = shift;
    my $isbn13 = shift;
    my $BookInfo = shift;

    print_debug(2, "GET Rainbowresource\n");
    push(@{$BookInfo}, '0', '0');
}

=head1 GetFromChristianbook
get book's price from Christianbook
mech
ISBN-13
Array With Data
=cut
sub GetFromChristianbook {
    my $mech   = shift;
    my $isbn13 = shift;
    my $BookInfo = shift;

    print_debug(2, "GET Christianbook\n");
    my $BMech = $mech->clone();
    # Doing a search
    # print $OtherPrices{'Christianbook'} . $isbn13, "\n";
    &ReTry($OtherPrices{'Christianbook'} . $isbn13 , $BMech, $MaxRetry, 1);
    my $Page  = HTML::TreeBuilder->new();
    $Page->ignore_unknown(0);
    $Page->parse_content(decode_utf8($BMech->content(decoded_by_headers => 1)));
    # <span class="CBD-ProductDetailActionPrice">
    my $span = $Page->look_down(_tag => 'span', 'class' => 'CBD-ProductDetailActionPrice' );
    if ($span) {
        my $price = $span->as_trimmed_text(extra_chars => '\xA0');
        $price =~ s/\$//;
        push(@{$BookInfo}, $price);
        my $FinalPrice = sprintf( '%.2f', $price * 0.98);
        push(@{$BookInfo}, $FinalPrice );
        if ($FinalPrice < $BestFinalPrice ) {
            $BestFinalPrice = $FinalPrice;
            $BestSellerPrice = 'ChristianBook';
        }
    } else {
        push(@{$BookInfo}, '0', '0');
    }
}


=head1 ReTry
Trying to get URL
Url
mech
RetryLimit
MaxSleep
=cut
sub ReTry {
    my $Url        = shift;
    my $mech       = shift;
    my $RetryLimit = shift;
    my $MaxSleep   = shift;
    $RetryLimit = 5 if(!$RetryLimit);
    $MaxSleep   = 1 if(!$MaxSleep);
    # Set a new timeout, and save the old one
    my $OldTimeOut = $mech->timeout(30);
    my $ErrMAdd;
    my $TryCount = 0;
    
    while ($TryCount <= $RetryLimit) {
        $TryCount++;
        sleep int(rand($MaxSleep));
        # Catch the error
        # Return if no error
        print_debug(3, "ReTry", $Url, "\n");
        eval { $mech->get($Url); };
        if ( $mech->response()->code ne "200") {
            return (1,$mech->response()->message);
        }
        if ($@) {
            print_debug(3, "Attempt $TryCount/$RetryLimit...\t$Url", $@, "\n");
            $ErrMAdd = $@;
        }
        else {
            print_debug(3, "ReTry Success\n");
            $mech->timeout($OldTimeOut); 
#            if ($mech->response()->code)
            return (1, "");
        }
    }
    # Restore old timeout
    $mech->timeout($OldTimeOut);    
    # Return failure if the program has reached here
    return (0,"Can't connect to $Url after $RetryLimit attempts ($ErrMAdd)....");
}

=head1 trim
trim leading and trailing spases 
str
=cut
sub trim {
    my $str = $_[0];
    $str = (defined($str)) ? $str : "";
    $str =~ s/^\s+|\s+$//g;
    return($str);
}

=head1 print_debug
print debug info
=cut
sub print_debug {
    my $level = shift;
    if ($level <= $DEBUG) {
        print STDERR join(" ", @_);
    }
}

=head Usage
print help screen
=cut
sub Usage {
    my $ProgName = shift;
    print <<EOF
Usage $ProgName [-s SleepTimeout] [ -p address:port] [-q ISBN-13] [-h]
  -h     display this help and exit.
  -s     set the Sleep Timeout between requests. $MaxSleep seconds by default.
  -p     set proxy address:port
  -q     check the code of one book

Script for scrapping website www.barnesandnoble.com

EOF
}

