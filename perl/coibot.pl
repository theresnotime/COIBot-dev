# COIBot - a Conflict Of Interest recognition bot for mediawiki projects.
# Written by Dirk Beetstra, 2007.
#
# COIBot reads link-addition feeds from IRC (e.g. #wikipedia-en-spam), && isolates the username, pagename && links added.
# It then compares the username with the pagename && the links added; a too big an overlap gets reported.

#First, let's declare our modules.
use strict;
#use warnings;
use POE;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::BotAddressed;
use DBI;

# Issue modules
#use Wikimedia;
#use Wikipedia;
#use perlwikipedia;

# Replacement modules
use MediaWiki::Bot qw(:constants);
use WWW::Wikipedia;

my %settings : shared;
$settings{limit}   = 25;                            # Initial setting, report above 25% overlap
$settings{reports} = 0;                             # number of reported cases in this run
$settings{RCReportLevel} = 0;                       # Reportlevel
$settings{LWReportLevel} = 1;                       # Reportlevel
$settings{ReportEvery} = 5;                         # Reports first && every 5
$settings{LookBackTime} = 3600;                     # Looks one hour back
$settings{StatsChannel} = '#wikipedia-spam-stats';  # Statistics are going to this channel
$settings{ReportChannel1} = '#wikipedia-spam-t';    # Reports are going to this channel
$settings{ReportChannel2} = '#wikipedia-en-spam';   # Reports are going to this channel
$settings{MaxToReport} = 50;                        # Reports a maximum of 50 last reports
$settings{deterioration} = 0.9;
$settings{reportcounter} = 0;
$settings{reportencounter} = 0;
$settings{reportmax} = 25;
$settings{boottime} = time();
$settings{lastsave} = time();
$settings{interval} = 900;
$settings{savecounter} = 0;
$settings{savecounteren} =0;
$settings{metaloginstatus} = 0;
$settings{enloginstatus} = 0;
$settings{messagecounter} = 0;
$settings{maxmessages} = 500;

$settings{report} = "";
$settings{reporten} = "";
$settings{savereport} = "";
$settings{savereporten} = "";


my @months : shared;
my @weekDays : shared;

my $page_grabber=Perlwikipedia->new;

#CONVERT this entire section
#Now we'll set up the mechanism we'll use for editing/retrieving pages
my $editor=MediaWiki::Bot->new;
my $mwusername='COIBot';
open(PASS,'COIBot-mw-password');          # A file with only the password, no carraige return
sysread(PASS, my $mwpassword, -s(PASS));     # No password in sourcecode.
close(PASS);
$mwpassword=~s/\n//;
my $login_status=$editor->login($mwusername,$mwpassword); #Log us in, cap'n!

unless ($login_status eq 'Success') { #Darn, we didn't log in
    die "Failed to log into Mediawiki.\n";
}
if ($login_status eq 'Success') { #We've logged in.
    print "Logged into Mediawiki.\n";
    $settings{enloginstatus} = 1;
}

my $eneditor=MediaWiki::Bot->new;
my $enusername='COIBot';
open(PASS,'COIBot-wp-password');          # A file with only the password, no carraige return
sysread(PASS, my $enpassword, -s(PASS));     # No password in sourcecode.
close(PASS);
$enpassword=~s/\n//;
my $enlogin_status=$eneditor->login($enusername,$enpassword); #Log us in, cap'n!

unless ($enlogin_status eq 'Success') { #Darn, we didn't log in
    die "Failed to log into Wikipedia.\n";
}
if ($enlogin_status eq 'Success') { #We've logged in.
    print "Logged into Wikipedia.\n";
    $settings{metaloginstatus} = 1;
}


#Declare all sorts of IRC-related goodness
my $nickname       = 'COIBot';                                             # Bots nickname
my $username       = 'COIBot';                                             # Bots username
open(PASS,'coibot-password');                                              # A file with only the password, no carriage return
sysread(PASS, my $password, -s(PASS));                                      # No password in sourcecode.
close(PASS);
$password=~s/\n//;                                                          # IRC password
my $ircname        = 'coibot COI recognition bot';                         # IRC name

my @rcchannels     = (                                                      # Listening to channels
    '#en.wikipedia',
    '#de.wikipedia',
    '#fr.wikipedia',
    '#it.wikipedia',
    '#nl.wikipedia',
    '#pl.wikipedia',                # 2 big ones not: ja (japanese) && zh (chinese)
    '#pt.wikipedia',
    '#es.wikipedia',
    '#no.wikipedia',
    '#ru.wikipedia',
    '#fi.wikipedia',
    '#sv.wikipedia'
);
my @lwchannels     = (            # Listening to channels
    $settings{ReportChannel1}, 
    $settings{ReportChannel2}, 
    $settings{StatsChannel}, 
    '#wikimedia-swmt',
    '#wikipedia-en-spam-bot'
);         


#declare the database goodies.
open(PASS,'COIBot-db-password');                                           # A file with only the password, no carriage return
sysread(PASS, my $coidbpass, -s(PASS));                                     # No password in sourcecode.
close(PASS);
$coidbpass=~s/\n//;                                                         # MySQL db password

@months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
@weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);

my $connections = {  # http://freenode.net/irc_servers.shtml
    'niven.freenode.net' => { port => 8001, channels => [ @lwchannels ], },
    'irc.wikimedia.org' => { port => 6667, channels => [ @rcchannels ], },
};

# We create a new PoCo-IRC objects && components.
foreach my $server ( keys %{ $connections } ) {
    POE::Component::IRC->spawn( 
            alias   => $server, 
            nick    => $nickname,
            ircname => $ircname,  
    );
}

POE::Session->create(
    inline_states => {
        _start  => \&_start,
        irc_disconnected   => \&bot_reconnect,
        irc_error          => \&bot_reconnect,
        irc_socketerr      => \&bot_reconnect,
        autoping           => \&bot_do_autoping,
        irc_registered     => \&irc_registered,
        irc_001            => \&irc_001,
        irc_public         => \&irc_public,
        irc_bot_addressed  => \&irc_bot_addressed,
    },
    heap => { config => $connections },
);

$poe_kernel->run();
exit 0;

sub bot_reconnect {
    my $kernel = $_[KERNEL];
    $kernel->delay( autoping => undef );
    $kernel->delay( connect  => 60 );
    undef $kernel;
}                

sub bot_do_autoping {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    $kernel->post( poco_irc => userhost => $nickname )
      unless $heap->{seen_traffic};
    $heap->{seen_traffic} = 0;
    $kernel->delay( autoping => 300 );
    undef $kernel;
    undef $heap;
}

sub _start {
    my ($kernel,$session) = @_[KERNEL,SESSION];
    
    # Send a POCOIRC_REGISTER signal to all poco-ircs
    $kernel->signal( $kernel, 'POCOIRC_REGISTER', $session->ID(), 'all' );
    
    undef $kernel;
    undef $session;
}

# We'll get one of these from each PoCo-IRC that we spawned above.
sub irc_registered {
    my ($kernel,$heap,$sender,$irc_object) = @_[KERNEL,HEAP,SENDER,ARG0];
    
    my $alias = $irc_object->session_alias();
    
    my %conn_hash = (
        server => $alias,
        port   => $heap->{config}->{ $alias }->{port},
    );
    
    # In any irc_* events SENDER will be the PoCo-IRC session
    $kernel->post( $sender, 'connect', \%conn_hash ); 
    $irc_object->plugin_add( 'BotAddressed', POE::Component::IRC::Plugin::BotAddressed->new(eat=>1) );    
    undef $kernel;
    undef $heap;
    undef $sender;
    undef $irc_object;
    undef $alias;
}

sub irc_001 {
    my ($kernel,$heap,$sender) = @_[KERNEL,HEAP,SENDER];
    
    # Get the component's object at any time by accessing the heap of
    # the SENDER
    my $poco_object = $sender->get_heap();
    print "Connected to ", $poco_object->server_name(), "\n";
    my $alias = $poco_object->session_alias();
    my @channels = @{ $heap->{config}->{ $alias }->{channels} };
    if ( $poco_object->server_name eq 'niven.freenode.net') {
        $kernel->post($sender=>privmsg=>"NickServ","identify $password");
        sleep 5;
        $kernel->post( $sender => join => $_ ) for @channels;
        $settings{reportserver} = $sender;
    }
    else {
        $kernel->post( $sender => join => $_ ) for @channels;
        $settings{readserver} = $sender;
    }
    undef $kernel;
    undef $heap;
    undef $sender;
    undef $poco_object;
    undef $alias;
    undef @channels;
    undef;
}

sub irc_public {
    my ($kernel,$heap,$sender,$who,$where,$message) = @_[KERNEL,HEAP,SENDER,ARG0,ARG1,ARG2];
    my $nick = (split /!/,$who)[0];
    my ($cloak)=( split /@/, $who)[1];
    my $channel   = $where->[0];
    my $page = "";
    my $page1 = "";
    my $page2 = "";
    my $url = "";
    my $garbage = "";
    my $lang = "";
    my $diff1 = "";
    my $diff2 = "";
    my $saveerror;
    my @arr = ();
    my $fulluser = "";
    my $user = "";
    my $diff = "";
    my $userlang = "";
    my $oldurl = "";
    my $fullurl = "";
    my $counter = 0;
    my $totalcounter = 0;
    my $second = "";
    my $minute = "";
    my $hour = "";
    my $dayOfMonth = "";
    my $month = "";
    my $yearOffset = "";
    my $dayOfWeek = "";
    my $dayOfYear = "";
    my $year = "";
    my $daylightSavings = "";
    my $theTime = "";
    my @reports = ();
    my $r1;
    my $r2;
    my $r3;
    my $r4;
    my $tr11;
    my $tr12;
    my $tr13;
    my $tr14;
    my $tr21;
    my $tr22;
    my $tr23;
    my $tr24;
    my $AtoB = 0;
    my $BtoA = 0;
    my $ratio = 0;
    my $today = "";
    my $reports = "";
    my $rcchannel;
    my $lwchannel;
    my $range;
    my $arr = "";
    my $currentreport = "";
    my $exists;
    my $resulting;
    my $server;
    my $checkmessage;
    my $verified;
    my $report;
    my $reporten;
    my $function;
    my @arrb;
    my $arrb;
    my $report2;
    my $toreport;
    my $fullpage;
    my @urls;
    my $whitelisted;
    my $prefix;    
    my $poco_object;
    my $alias;
    my @channels;
    $message =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;          # Kill any color codes.
    $checkmessage = lc($message);
    if ($checkmessage=~ m/^night $nickname/) {
        print("GOING DOWN!\r\n");
        if (lc($cloak) eq "wikimedia/beetstra" || lc($cloak) eq "wikimedia/versageek") {
            $saveerror = 0;
            $kernel->post( $sender => privmsg => $channel =>  "Night everyone!");
            if (length($settings{report}) > 0) {
                ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time());
                $year = 1900 + $yearOffset;
                $today = "$year, $months[$month] $dayOfMonth";
                $settings{savereport} .= $settings{report};
                $settings{savereporten} .= $settings{reporten};
                $settings{savecounter} = $settings{savecounter} + $settings{reportcounter};
                $settings{savecounteren} = $settings{savecounteren} + $settings{reportencounter};
                $settings{reportcounter} = 0;
                $settings{reportencounter} = 0;
                delete $settings{report};
                $settings{report} = "";
                delete $settings{reporten};
                $settings{reporten} = "";
                eval {
                    $report2 = $eneditor->grab_text("Wikipedia:WikiProject Spam/COIReports/$today");
                };
                if ($@) {
                    $kernel->post( $sender => privmsg => $channel => "ERROR! while reading from to en.wikipedia ($nickname will not quit)." );
                    $saveerror = 1;
                } else {
                    $report2 .= $settings{savereporten};
                    $report2 =~ s/amp;//g;
                    eval {
                        $eneditor->edit("Wikipedia:WikiProject Spam/COIReports/$today","$nickname save - $settings{savecounteren} reports (quit).",$report2);
                    };
                    if ($@) {
                        $kernel->post( $sender => privmsg => $channel => "ERROR! while saving to en.wikipedia ($nickname will not quit)." );
                        $saveerror = 0;
                    } else {
                        $kernel->post( $sender => privmsg => $channel => "Saved to en.wikipedia (quit)." );
                        delete $settings{savereporten};
                        $settings{savereporten} = "";
                        $settings{savecounteren} = 0;
                    }
                }
                eval {
                    $report2 = $editor->grab_text("User:COIBot/COIReports/$today");
                };
                if ($@) {
                    $kernel->post( $sender => privmsg => $channel => "ERROR! While reading from to meta.wikimedia." );
                    $saveerror = 1;
                } else {
                    $report2 .= $settings{savereport};
                    $report2 =~ s/amp;//g;
                    eval {
                        $editor->edit("User:COIBot/COIReports/$today","$nickname save - $settings{savecounter} reports (quit).",$report2);
                    };
                    if ($@) {
                        $kernel->post( $sender => privmsg => $channel => "ERROR! While saving to meta.wikimedia." );
                        $saveerror = 1;
                    } else {
                        $kernel->post( $sender => privmsg => $channel => "Saved to meta.wikimedia (quit)." );
                        delete $settings{savereport};
                        $settings{savereport} ="";
                        $settings{savecounter} = 0;
                    }
                }
            } 
            if ($saveerror == 0) {
                $kernel->signal($kernel, 'POCOIRC_SHUTDOWN', "Night everyone!");
            }
        } elsif ($verified == 0) {
            $kernel->post( $sender => privmsg => $channel => "Thank you, $nick, a good night to you too, sleep carefully!" );
        }
    }

    if ( ($nick eq "Vix-LW" || $nick eq "EN-LW" || $nick eq "VixEN-LW" || $nick eq "AALinkWatcher") && (($checkmessage =~ m/^\[\[(.+)/ ) || ($checkmessage =~ m/^item on bl for bot reversion: \[\[(.+)/ ) ) ) {
        $settings{messagecounter}++;
        $settings{reporting} = 1;
        $toreport = 0;
        ($garbage,$message) = split(/\[\[/,$message,2);                     # split of the [[
        ($fullpage,$message) = split(/\]\]/,$message,2);                    # pagename ends with first ]]
        ($lang,$page) = split(/:/,$fullpage,2);                             #  divided in language && pagename
        ($diff,$message) = split(/\[\[/,$message,2);                        # username starts with [[, before that is diff
        ($fulluser,$message) = split(/\]\]/,$message,2);                    # username ends with ]], after that the urls
        ($userlang,$user) = split(/\:User\:/,$fulluser,2);                  #  divided username in lang, 'user' && username
        @arr = get_mysql('whitelist','user',lc($user));                     # find user in whitelist
        if (@arr) {
            if (@arr[0]->{1} == -1 ) {
                print("Error occured in whitelist retrieval.\n" );
                @arr=();
            }
        }
        ($garbage,$message) = split(/\:\/\//,$message,2);
        print ("read LW: $lang - $page - $user - $message - $diff\n");
        @arrb = get_mysql('blacklist','user',lc($user));                    # Now see if username is connected to strings in blacklist
        if (@arrb) {
            if (@arrb[0]->{1} == -1 ) {
                print ("Error occured in blacklist retrieval.\n" );
                @arrb = ();
            }
        }
        @urls = split(/\:\/\//,$message);                                   # all urls are divided by ]\s[
        foreach $url(@urls) {                                               # For all urls ...
            $url = lc($url);
            $url = $url . " /]";                                            # parse 'm ..
            ($url,$garbage) = split (/\s/,$url,2);
            ($url,$garbage) = split (/\"/,$url,2);
            $fullurl = $url;                                                # save the full url
            ($url,$garbage) = split (/\//, $url,2);                           # domain is in front of the first / (if any)
            if (length ($url) == 0) {                                       # no ending /, then url is in garbage
                $url = $garbage 
            }
            ($url,$garbage) = split (/\?/, $url,2);                           # domain is in front of the first ? (if any)
            if (length ($url) == 0) {                                       # no ending ?, then url is in garbage
                $url = $garbage;
            }
            $url =~ s/www\.//s;                                             # remove some st&&ard stuff, seldomly included in username
            $url =~ s/www3\.//s;
            $whitelisted = 0;
            foreach $arr(@arr) {                                            # find in whitelist
                if (lc($url) eq lc($arr->{1})) { 
                    print("  $page <-> $url\n");
                    $whitelisted = 1;
                } elsif ($arr->{1} eq "*") {
                    print("  Whitelisted user $user\n");
                    $whitelisted = 1;
                }
            }
            $resulting = 0;
            if ($whitelisted == 0) {                                    # not whitelisted
                $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$url,"U","L",$diff,"LW");
                unless ($resulting == 1) {
                    if (@arrb) {
                        unless (@arrb[0]->{1} == -1 ) {
                            foreach $arrb(@arrb) {                                                # explanation, see above
                                unless ($resulting ==1) {
                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$arrb->{2},$url,"R","L",$diff,"LW");
                                }
                            }
                        }
                    }
                    unless ($resulting == 1) {
                        @arr = get_mysql('blacklist','string',lc($url));                      # Now see if url is connected to strings in blacklist
                        if (@arr) {
                            if (@arr[0]->{1} == -1 ) {
                                print("Error occured in blacklist retrieval.\n" );
                            } else {
                                foreach $arr(@arr) {                                                # explanation, see above
                                    if ($user =~ m/(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
                                        $r1 = $1;
                                        $r2 = $2;
                                        $r3 = $3;
                                        $r4 = $4;
                                        if ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+)\.(\d+)-(\d+)\.(\d+)\.(\d+)\.(\d+)/ ) {
                                            $tr11 = $1;
                                            $tr12 = $2;
                                            $tr13 = $3;
                                            $tr14 = $4;
                                            $tr21 = $5;
                                            $tr22 = $6;
                                            $tr23 = $7;
                                            $tr24 = $8;
                                            print("    Range -> $range\n");
                                            if ($r1 >= $tr11 && $r1 <= $tr21 && $r2 >= $tr12 && $r2 <= $tr22 && $r3 >= $tr13 && $r1 <= $tr23 && $r4 >= $tr14 && $r1 <= $tr24) {
                                                unless ($resulting ==1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } elsif ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+).(\d+)\/(\d+)/) {
                                            if(inCIDRrange($1,$2,$3,$4,$5,$r1,$r2,$r3,$r4)) {
                                                unless ($resulting == 1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } elsif ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+)\/(\d+)/) {
                                            if(inCIDRrange($1,$2,$3,0,$5,$r1,$r2,$r3,$r4)) {
                                                unless ($resulting == 1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } else {
                                            unless ($resulting == 1) {
                                                $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$arr->{1},$user,"R","U",$diff,"LW");
                                            }
                                        }
                                    } else {
                                        unless ($resulting ==1) {
                                            $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$arr->{1},$user,"R","U",$diff,"LW");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if  (($nick eq "Vix-LW" || $nick eq "EN-LW" || $nick eq "AALinkWatcher") && ($checkmessage =~ m/^diff=\<(.+)/ )) {
        $settings{messagecounter}++;
        $settings{reporting} = 1;
        ($garbage,$message) = split(/diff=\</,$message,2);
        ($diff,$message) = split(/\>\suser=\</,$message,2);
        ($user,$message) = split(/\>\stitle=\</,$message,2);
        ($page,$message) = split(/\>\ssize=\</,$message,2);
        ($garbage,$message) = split(/\>\srule=\</,$message,2);
        $lang = 'en';
        print ("read LW: $lang - $page - $user - $diff\n");
        @arr = get_mysql('whitelist','user',lc($user));                      # find user in whitelist
        if (@arr) {
            if (@arr[0]->{1} == -1 ) {
                print ("Error occured in whitelist retrieval.\n" );
                @arr=();
            }
        }
        $whitelisted = 0;
        @arrb = get_mysql('blacklist','user',lc($user));                      # Now see if username is connected to strings in blacklist
        if (@arrb) {
            if (@arrb[0]->{1} == -1 ) {
                print ("Error occured in blacklist retrieval.\n" );
                @arrb = ();
            }
        }
        @urls = split(/rule=/,$message);                                 # 
        foreach $url(@urls) {                                               # For all urls ...
            $url = lc($url);
            ($prefix,$url) = split (/\</,$url,2);
            if (length($url)==0) {
                $url = $prefix;
            }
            ($url,$garbage) = split (/\>/,$url,2);
            $url =~ s/\\b//g;
            $url =~ s/\\//g;
            ($url,$garbage) =~ split(/\//,2);
            ($url,$garbage) =~ split(/\?/,2);
            $url =~ s/www\.//;                                             # remove some st&&ard stuff, seldomly included in username
            $url =~ s/www3\.//;
            $whitelisted = 0;
            foreach $arr(@arr) {                                            # find in whitelist
                if (lc($url) eq lc($arr->{1})) { 
                    print("  $page <-> $url\n");
                    $whitelisted = 1;
                } elsif ($arr->{1} eq "*") {
                    print("  Whitelisted user $user\n");
                    $whitelisted = 1;
                }
            }
            $resulting = 0;
            if ($whitelisted == 0) {                                    # not whitelisted
                $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$url,"U","L",$diff,"LW");
                unless ($resulting == 1) {
                    if (@arrb) {
                        unless (@arrb[0]->{1} == -1 ) {
                            foreach $arrb(@arrb) {                                                # explanation, see above
                                unless ($resulting ==1) {
                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$arrb->{2},$url,"R","L",$diff,"LW");
                                }
                            }
                        }
                    }
                    unless ($resulting == 1) {
                        @arr = get_mysql('blacklist','string',lc($url));                      # Now see if url is connected to strings in blacklist
                        if (@arr) {
                            if (@arr[0]->{1} == -1 ) {
                                print("Error occured in blacklist retrieval.\n" );
                            } else {
                                foreach $arr(@arr) {                                                # explanation, see above
                                    if ($user =~ m/(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
                                        $r1 = $1;
                                        $r2 = $2;
                                        $r3 = $3;
                                        $r4 = $4;
                                        if ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+)\.(\d+)-(\d+)\.(\d+)\.(\d+)\.(\d+)/ ) {
                                            $tr11 = $1;
                                            $tr12 = $2;
                                            $tr13 = $3;
                                            $tr14 = $4;
                                            $tr21 = $5;
                                            $tr22 = $6;
                                            $tr23 = $7;
                                            $tr24 = $8;
                                            print("    Range -> $range\n");
                                            if ($r1 >= $tr11 && $r1 <= $tr21 && $r2 >= $tr12 && $r2 <= $tr22 && $r3 >= $tr13 && $r1 <= $tr23 && $r4 >= $tr14 && $r1 <= $tr24) {
                                                unless ($resulting ==1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } elsif ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+).(\d+)\/(\d+)/) {
                                            if(inCIDRrange($1,$2,$3,$4,$5,$r1,$r2,$r3,$r4)) {
                                                unless ($resulting == 1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } elsif ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+)\/(\d+)/) {
                                            if(inCIDRrange($1,$2,$3,0,$5,$r1,$r2,$r3,$r4)) {
                                                unless ($resulting == 1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } else {
                                            unless ($resulting == 1) {
                                                $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$arr->{1},$user,"R","U",$diff,"LW");
                                            }
                                        }
                                    } else {
                                        unless ($resulting ==1) {
                                            $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$arr->{1},$user,"R","U",$diff,"LW");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if ( $nick eq "rc" ) {
        ($page,$message) = split(/\]\]\s/,$message,2);
        ($garbage,$page) = split(/\[\[/,$page,2);
        ($diff,$message) = split(/\s\*\s/,$message,2);
        ($user,$message) = split(/\s\*\s/,$message,2);
        ($function,$diff) = split(/\s/,$diff);
        ($lang,$garbage) = split(/\./,$channel,2);
        $lang =~ s/#//;
        if (length($diff) ==  0) {
            $diff = $function;
            $function="";
        }
        ($page1,$page2) = split(/:/,$page,2);
        $page = "";
        if (length($page2) == 0) {
            $page=$page1;
        } 
        print ("read RC: $lang - $page - $user - $diff\n");
        if (length($page)>0) {    
            if ($function eq 'create') {
                #new user
            } elsif ($function eq 'move') {
            } elsif ($function eq 'delete') {
            } elsif ($function eq 'block') {
            } elsif ($function eq 'unblock') {
            } elsif ($function eq 'upload') {
            } else {
                $whitelisted = 0;
                @arr = get_mysql('whitelist','user',lc($user));                      # find user in whitelist
                if (@arr) {
                    if (@arr[0]->{1} == -1 ) {
                        print ("Error occured in whitelist retrieval.\n" );
                        @arr=();
                    }
                }
                foreach $arr(@arr) {                                            # find in whitelist
                    if (lc($page) eq lc($arr->{1})) { 
                        print("  $page <-> $arr->{1}\n");
                        $whitelisted = 1;
                    } elsif ($arr->{1} eq "*") {
                        print("  Whitelisted user $user\n");
                        $whitelisted = 1;
                    }
                }        
                $resulting = 0;
                if ($whitelisted == 0) {
                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,"","",$user,$page,"U","P",$diff,"RC");
                    unless ($resulting == 1) {
                        @arr = get_mysql('blacklist','user',lc($user));                      # find user in whitelist
                        if (@arr) {
                            if (@arr[0]->{1} == -1 ) {
                                print ("Error occured in blacklist retrieval.\n" );
                            } else {
                                foreach $arr(@arr) {                                                # explanation, see above
                                    unless ($resulting ==1) {
                                        $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,"","",$arr->{2},$page,"R","P",$diff,"RC");
                                    }
                                }
                            }
                            unless ($resulting == 1) {
                                foreach $arr(@arr) {                                                # explanation, see above
                                    if ($user =~ m/(\d+)\.(\d+)\.(\d+)\.(\d+)/) {
                                        $r1 = $1;
                                        $r2 = $2;
                                        $r3 = $3;
                                        $r4 = $4;
                                        if ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+)\.(\d+)-(\d+)\.(\d+)\.(\d+)\.(\d+)/ ) {
                                            $tr11 = $1;
                                            $tr12 = $2;
                                            $tr13 = $3;
                                            $tr14 = $4;
                                            $tr21 = $5;
                                            $tr22 = $6;
                                            $tr23 = $7;
                                            $tr24 = $8;
                                            print("    Range -> $range\n");
                                            if ($r1 >= $tr11 && $r1 <= $tr21 && $r2 >= $tr12 && $r2 <= $tr22 && $r3 >= $tr13 && $r1 <= $tr23 && $r4 >= $tr14 && $r1 <= $tr24) {
                                                unless ($resulting ==1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } elsif ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+).(\d+)\/(\d+)/) {
                                            if(inCIDRrange($1,$2,$3,$4,$5,$r1,$r2,$r3,$r4)) {
                                                unless ($resulting == 1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } elsif ($arr->{1} =~ m/(\d+)\.(\d+)\.(\d+)\/(\d+)/) {
                                            if(inCIDRrange($1,$2,$3,0,$5,$r1,$r2,$r3,$r4)) {
                                                unless ($resulting == 1) {
                                                    $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$user,$user,"R","U",$diff,"LW");
                                                }
                                            }
                                        } else {
                                            unless ($resulting == 1) {
                                                $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$arr->{1},$user,"R","U",$diff,"LW");
                                            }
                                        }
                                    } else {
                                        unless ($resulting ==1) {
                                            $resulting = compareandreport($channel,$kernel,$sender,$lang,$user,$page,$url,$fullurl,$arr->{1},$user,"R","U",$diff,"LW");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }    
    
    if ( $settings{messagecounter} > $settings{maxmessages}) {
        foreach $rcchannel(@rcchannels) {
            $kernel->post( $settings{readserver} => join => $rcchannel );
        }
        $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "Refreshed login on @rcchannels" );
        foreach $lwchannel(@lwchannels) {
            $kernel->post( $settings{reportserver} => join => $lwchannel );
        }
        $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "Refreshed login on @lwchannels" );
        $settings{messagecounter} = 0;

    }
    
    if ( ($settings{reportcounter} > ($settings{reportmax}-1)) && length($settings{report}) > 0 ) {
        ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time());
        $year = 1900 + $yearOffset;
        $today = "$year, $months[$month] $dayOfMonth";
        $settings{savereport} .= $settings{report};
        $settings{savecounter} = $settings{savecounter} + $settings{reportcounter};
        $settings{reportcounter} = 0;
        delete $settings{report};
        $settings{report} = "";

        $login_status=$editor->login($mwusername,$mwpassword); #Log us in, cap'n!
        unless ($login_status eq 'Success') { #Darn, we didn't log in
            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ERROR! Failed to login to meta.wikimedia." );
            $settings{metaloginstatus} = 0;
        }
        if ($login_status eq 'Success') { #We've logged in.
            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "Login refreshed on meta.wikimedia!" );
            $settings{metaloginstatus} = 0;
            eval {
                $report2 = $editor->grab_text("User:COIBot/COIReports/$today");
            };
            if ($@) {
                $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ERROR! While reading from to meta.wikimedia." );
            } else {
                $report2 .= $settings{savereport};
                $report2 =~ s/amp;//g;
                eval {
                    $editor->edit("User:COIBot/COIReports/$today","$nickname save - $settings{savecounter} reports.",$report2);
                };
                if ($@) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ERROR! While saving to meta.wikimedia (please check block log)." );
                } else {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "Saved to meta.wikimedia." );
                    delete $settings{savereport};
                    $settings{savereport} ="";
                    $settings{savecounter} = 0;
                }
            }
        }
    }
    if ( ($settings{reportencounter} > ($settings{reportmax}-1)) && length($settings{reporten}) > 0 ) {
        ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time());
        $year = 1900 + $yearOffset;
        $today = "$year, $months[$month] $dayOfMonth";
        $settings{savereporten} .= $settings{reporten};
        $settings{savecounteren} = $settings{savecounteren} + $settings{reportencounter};
        $settings{reportencounter} = 0;
        delete $settings{reporten};
        $settings{reporten} = "";
        $enlogin_status=$eneditor->login($enusername,$enpassword); #Log us in, cap'n!
        unless ($enlogin_status eq 'Success') { #Darn, we didn't log in
            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ERROR! Failed to login to en.wikipedia" );
            $settings{metaloginstatus} = 0;
        }
        if ($enlogin_status eq 'Success') { #We've logged in.
            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "Login refreshed on en.wikipedia!" );
            $settings{metaloginstatus} = 1;
            eval {
                $report2 = $eneditor->grab_text("Wikipedia:WikiProject Spam/COIReports/$today");
            };
            if ($@) {
                $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ERROR! while reading from to en.wikipedia." );
            } else {
                $report2 .= $settings{savereporten};
                $report2 =~ s/amp;//g;
                eval {
                    $eneditor->edit("Wikipedia:WikiProject Spam/COIReports/$today","$nickname save - $settings{savecounteren} reports.",$report2);
                };
                if ($@) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ERROR! while saving to en.wikipedia." );
                } else {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "Saved to en.wikipedia." );
                    delete $settings{savereporten};
                    $settings{savereporten} = "";
                    $settings{savecounteren} = 0;
                }
            }
        }
    }
    undef $kernel;
    undef $heap;
    undef $sender;
    undef $who;
    undef $where;
    undef $message;
    undef $nick;
    undef $cloak;
    undef $channel;
    undef $page;
    undef $page1;
    undef $page2;
    undef $url;
    undef $garbage;
    undef $lang;
    undef $server;
    undef $diff1;
    undef $diff2;
    undef $saveerror;
    undef @arr;
    undef $fulluser;
    undef $user;
    undef $diff;
    undef $userlang;
    undef $oldurl;
    undef $fullurl;
    undef $counter;
    undef $totalcounter;
    undef $second;
    undef $minute;
    undef $hour;
    undef $dayOfMonth;
    undef $arrb;
    undef $exists;
    undef $arrb;
    undef $month;
    undef $yearOffset;
    undef $dayOfWeek;
    undef $dayOfYear;
    undef $year;
    undef $daylightSavings;
    undef $theTime;
    undef @reports;
    undef $AtoB;
    undef $BtoA;
    undef $ratio;
    undef $today;
    undef $reports;
    undef $rcchannel;
    undef $lwchannel;
    undef $arr;
    undef $currentreport;
    undef $checkmessage;
    undef $verified;
    undef $report;
    undef $reporten;
    undef $function;
    undef $r1;
    undef $r2;
    undef $r3;
    undef $r4;
    undef $tr11;
    undef $tr12;
    undef $tr13;
    undef $tr14;
    undef $tr21;
    undef $tr22;
    undef $tr23;
    undef $tr24;
    undef $range;
    undef $report2;
    undef $toreport;
    undef $fullpage;
    undef @urls;
    undef $whitelisted;
    undef $prefix;    
    undef $poco_object;
    undef $alias;
    undef @channels;
    undef;
}

sub irc_bot_addressed {                                                     # Bot comm&&s
    my ($kernel,$heap,$sender,$who,$where,$message) = @_[KERNEL,HEAP,SENDER,ARG0,ARG1,ARG2];
    my $nick = (split /!/,$who)[0];
    my ($cloak)=( split /@/, $who)[1];
    my $channel   = $where->[0];
    $message =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g; #Kill any color codes.
    my $checkmessage = lc($message);
    my $message_to_send = "";
    my $newchannel = "";
    my $verified = "";
    my $oldchannel = "";
    my $toreport = "";
    my @reports = ();
    my $coicounter = "";
    my $report = "";
    my $AtoB = 0;
    my $BtoA = 0;
    my $ratio = 0;
    my $theTime="";
    my $outputtext = "";
    my $average;
    my $poco_object;
    my $alias;
    my @channels;
    my $url1 = "";
    my $page1 = "";
    my $report2;
    my $uptime;
    my $channel2;
    my $counter = 1;
    my $today;
    my $currentreport;
    my $second = "";
    my $minute = "";
    my $hour = "";
    my $dayOfMonth = ""; 
    my $reporten;
    my $month = ""; 
    my $channels;
    my $blacklist;
    my $whitelist;
    my $yearOffset = ""; 
    my $dayOfWeek = ""; 
    my $dayOfYear = ""; 
    my $daylightSavings = "";
    my $user1 = "";
    my $garbage = "";
    my $numbertoreport = "";
    my $deterioration = 0;
    my $limit = "";
    my $lookbacktime = "";
    my $reportevery = "";
    my $user = "";
    my $strng = "";
    my $exte = "";
    my @blacklist;
    my @whitelist;
    my $name = "";
    my $server;
    my $reason;
    my $result;
    my $exists = "";
    my @arr = ();
    my $outstring = "";
    my $reports = "";
    my $year = "";
    my $arr = "";
    my $saveerror;
    my $totrust = "";
    my $reportlevel = 0;
    my $toreport2;
    my $timedifference;
    if ( ($channel eq $settings{ReportChannel1}) || ($channel eq $settings{ReportChannel2}) || ($channel eq $settings{StatsChannel}) || ($channel eq '#BeetstraBotChannel') ) {

        if ($checkmessage=~ m/^status/ ) {                                  # ask for status
            $timedifference = time() - $settings{boottime};
            $minute = int($timedifference / 60);
            $second = $timedifference - $minute * 60;
            $hour = int($minute / 60);
            $minute = $minute - $hour * 60;
            $dayOfYear = int($hour / 24);
            $hour = $hour - $dayOfYear * 24;
            if (length("$hour") == 1) {
                $hour = "0$hour";
            }
            if (length("$minute") == 1) {
                $minute = "0$minute";
            }
            if (length("$second") == 1) {
                $second = "0$second";
            }
            if ($dayOfYear > 1) {
                $theTime = "$dayOfYear days, $hour:$minute:$second hours";
            } elsif ($dayOfYear == 1) {
                $theTime = "$dayOfYear day, $hour:$minute:$second hours";
            } else {
                if ($hour > 1) {
                    $theTime = "$hour hours $minute:$second minutes";
                } elsif ($hour == 1) {
                    $theTime = "$hour hour $minute:$second minutes";
                } else {
                    if ($minute > 1) {
                        $theTime = "$minute minutes $second seconds";
                    } elsif ($minute == 1) {
                        $theTime = "$minute minute $second seconds";
                    } else {
                        $theTime = "$second seconds";
                    }
                }
            }
            $uptime = ($dayOfYear * 60 * 24) + ($hour * 60) + $minute;
            if ($uptime > 0) {
                $average = int (100 * $settings{reports} / $uptime) / 100; 
            } else {
                $average = 0;
            }
            $message_to_send="$nick:";
            if ($settings{reports} != 0) {
                if ($settings{reports} == 1) {
                    $message_to_send.=" I have reported one COI suspect in $theTime ($average/min).";
                } else {
                    $message_to_send.=" I have reported $settings{reports} COI suspects in $theTime ($average/min).";
                }
            } else {
                $message_to_send.=" I have reported no COI suspects in $theTime.";
            }
            $message_to_send.=" I report when overlap is more than $settings{limit}%.";
            
            $message_to_send.=" Reporting to $settings{ReportChannel1} (limited) && $settings{ReportChannel2} (all); LW report level is $settings{LWReportLevel}";
            if ($settings{LWReportLevel} == 1 || $settings{LWReportLevel} == 3) {
                $message_to_send.=" (reporting first && every $settings{ReportEvery} additions)"
            }
            $message_to_send.=" && RC report level is $settings{RCReportLevel}";
            if ($settings{RCReportLevel} == 1 || $settings{RCReportLevel} == 3) {
                $message_to_send.=" (reporting first && every $settings{ReportEvery} additions)"
            }
            $message_to_send.=". Saving every $settings{reportmax} additions ($settings{reportcounter} in current batch).";
            $kernel->post( $sender => privmsg => $channel => $message_to_send );
        }
        
        if ($checkmessage=~ m/^channels/ ) {                                # ask for which channels coibot is on
            $poco_object = $settings{reportserver}->get_heap();
#            @channels = $poco_object->channels();
            $channels = join(", ",@lwchannels);
            $server = $poco_object->server_name();
            $message_to_send = "$nickname reports to && listens on $server to $channels && ";
            $poco_object = $settings{readserver}->get_heap();
#            @channels = $poco_object->channels();
            $channels = join(", ",@rcchannels);
            $server = $poco_object->server_name();
            $message_to_send .= "$nickname listens on $server to $channels.";
            $kernel->post( $sender => privmsg => $channel => $message_to_send );
        }

        if ($checkmessage=~ m/^add lwchannel (.+)/ || $checkmessage=~ m/^add channel (.+)/ || $checkmessage=~ m/^join lwchannel (.+)/ || $checkmessage=~ m/^join channel (.+)/) {                        # make coibot join a channel (restricted)
            $newchannel = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                if (grep(/$newchannel/,@lwchannels)) {
                    $kernel->post( $sender => privmsg => $channel => "Channel $newchannel already joined." );
                } else {
                    push (@lwchannels,$newchannel);
                    $kernel->post( $settings{reportserver} => join => $newchannel );
                    $kernel->post( $sender => privmsg => $channel => "$nickname is now also parsing $newchannel." );
                    $kernel->post( $sender => privmsg => $newchannel => "$nickname is now also parsing $newchannel." );
                    print "Connected to $newchannel.\n";
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~ m/^part lwchannel (.+)/ || $checkmessage=~ m/^part channel (.+)/ ) {                        # make coibot part a channel (restricted)
            $oldchannel = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $channel2 = join(",",@lwchannels);
                $channel = "!!$channel2";
                if ($channel =~ m/$oldchannel/) {
                    $kernel->post( $settings{reportserver} => part => $oldchannel );
                    $channel =~ s/,$oldchannel//;
                    $channel =~ s/!$oldchannel//;
                    $channel =~ s/!,//g;
                    $channel =~ s/!//g;
                    @lwchannels = split(/,/,$channel);
                    $kernel->post( $sender => privmsg => $channel => "$nickname has parted $oldchannel." );
                    print "Parted $oldchannel on freenode.\n";
                } else {
                    $kernel->post( $sender => privmsg => $channel => "Channel $oldchannel not in list." );
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                    $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~ m/^add rcchannel (.+)/ || $checkmessage=~ m/^join rcchannel (.+)/ ) {                        # make coibot join a channel (restricted)
            $newchannel = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                if (grep(/$newchannel/,@rcchannels)) {
                    $kernel->post( $sender => privmsg => $channel => "Channel $newchannel already joined." );
                } else {
                    push (@rcchannels,$newchannel);
                    $kernel->post( $settings{readserver} => join => $newchannel );
                    $kernel->post( $sender => privmsg => $channel => "$nickname is now also parsing $newchannel." );
                    print "Connected to $newchannel.\n";
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~ m/^part rcchannel (.+)/ ) {                        # make coibot part a channel (restricted)
            $oldchannel = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $channel2 = join(",",@rcchannels);
                $channel = "!!$channel2";
                if ($channel =~ m/$oldchannel/) {
                    $kernel->post( $settings{readserver} => part => $oldchannel );
                    $channel =~ s/,$oldchannel//;
                    $channel =~ s/!$oldchannel//;
                    $channel =~ s/!,//g;
                    $channel =~ s/!//g;
                    @rcchannels = split(/,/,$channel);
                    $kernel->post( $sender => privmsg => $channel => "$nickname has parted $oldchannel." );
                    print "Parted $oldchannel on freenode.\n";
                } else {
                    $kernel->post( $sender => privmsg => $channel => "Channel $oldchannel not in list." );
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                    $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^report link (.+)/) {                          # ask for a report on a link
            @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
            @weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
            $toreport = $1;
            $coicounter = 0;
            @reports = get_mysql('report','link',$toreport);
            if (@reports) {
                if (@reports[0]->{1} == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error occured in report retrieval.\n" );
                } else {
                    $report = "";
                    foreach $reports(@reports) {
                        $coicounter++;
                    }
                }
            }
            $toreport = lc($toreport);
            if ($coicounter == 0) {
                $kernel->post( $sender => privmsg => $channel => "No records on link $toreport; nothing to report." );
            } else {
                @blacklist = get_mysql('blacklist','string',$toreport);
                if (@blacklist) {
                    if (@blacklist[0]->{1} == -1) {
                        print( "Error occured in blacklist retrieval.\n" );
                        @blacklist = ();
                    }
                }
                @whitelist = get_mysql('whitelist','string',$toreport);
                if (@whitelist) {
                    if (@whitelist[0]->{1} == -1) {
                        print( "Error occured in whitelist retrieval.\n" );
                        @whitelist = ();
                    }
                }
                $kernel->post( $sender => privmsg => $channel => "Reporting statistics of link $toreport to $settings{StatsChannel}; $coicounter records (see [[m:User:COIBot/LinkReports/$toreport]])." );
                $report = "Reporting statistics of link $toreport; $coicounter records.";
                $report .= "\r\n* [http://en.wikipedia.org/wiki/Wikipedia:WikiProject_Spam/LinkSearch/$toreport Link report] - [http://tools.wikimedia.de/~eagle/linksearch?search=$toreport Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$toreport Eagle's Spamsearch]";
                $reporten = "Reporting statistics of link $toreport; $coicounter records.";
                $reporten .= "\r\n* [http://en.wikipedia.org/wiki/Wikipedia:WikiProject_Spam/LinkSearch/$toreport Link report] - [http://tools.wikimedia.de/~eagle/linksearch?search=$toreport Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$toreport Eagle's Spamsearch]";
                $kernel->post( $sender => privmsg => $settings{StatsChannel} => "Reporting statistics of link $toreport; $coicounter records." );
                if (@blacklist) {
                    $report .= "\r\n* Blacklist search for link $toreport gives: ";
                    $reporten .= "\r\n* Blacklist search for link $toreport gives: ";
                    foreach $blacklist(@blacklist) {
                      $report .= "\r\n:* $blacklist->{1} ($blacklist->{3})";
                      $reporten .= "\r\n:* $blacklist->{1} ($blacklist->{3})";
                    }
                }
                if (@whitelist) {
                    $report .= "\r\n* Whitelist search for link $toreport gives:";
                    $reporten .= "\r\n* Whitelist search for link $toreport gives:";
                    foreach $whitelist(@whitelist) {
                      $report .= "\r\n:* $whitelist->{1} ($whitelist->{3})";
                      $reporten .= "\r\n:* $whitelist->{1} ($whitelist->{3})";
                    }
                }
                $report .= "\r\n\r\nReports";
                $reporten .= "\r\n\r\nReports";
                $AtoB = 0;
                $BtoA = 0;
                $ratio = 0;
                $theTime="";
                $outputtext = "";
                $url1 = "";
                $page1 = "";
                $counter = 1;
                foreach $reports(@reports) {    #username, language, page, url, fullurl, diff, time
                    ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime($reports->{7});
                    $year = 1900 + $yearOffset;
                    if (length("$hour") == 1) {
                        $hour = "0$hour";
                    }
                    if (length("$minute") == 1) {
                        $minute = "0$minute";
                    }
                    if (length("$second") == 1) {
                        $second = "0$second";
                    }
                    if (length("$dayOfMonth") == 1) {
                        $dayOfMonth = "0$dayOfMonth";
                    }
                    $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
                    $user1 = $reports->{1};
                    $url1=lc($reports->{4});
                    $page1=$reports->{3};
                    if (length($reports->{4}) > 0 ) {
                        ($url1,$garbage) = split (/\//, $url1,2);
                        $url1 =~ s/www//s;
                        $url1 =~ s/www3\.//s;
                        $url1 =~ s/\.//s;
                        $AtoB = weighing($user1,$url1);
                        $BtoA = weighing($url1,$user1);
                        $ratio = int(($AtoB * $BtoA)/10)/10;    #username, language, page, url, fullurl, diff, time
                        $outputtext = "$theTime [[$reports->{2}:user:$reports->{1}]] <-> $reports->{4} ($AtoB%/$BtoA%/$ratio%) - [[$reports->{2}:$reports->{3}]]";
                        $kernel->post( $sender => privmsg => $settings{StatsChannel} => "* $counter $outputtext - ($reports->{6})" );
                        $reports->{6} =~ s/\s//g;
                        $report .="\r\n# $outputtext - [$reports->{6} diff] - [[User:COIBot/UserReports/$reports->{1}|COIBot UserReport]].";
                        $reporten .="\r\n# $outputtext - [$reports->{6} diff] - [[Wikipedia:WikiProject Spam/UserReports/$reports->{1}|COIBot UserReport]].";
                    } else {                    
                        $AtoB = weighing($user1,$page1);
                        $BtoA = weighing($page1,$user1);
                        $ratio = int(($AtoB * $BtoA)/10)/10;
                        $outputtext = "$theTime [[$reports->{2}:user:$reports->{1}]] <-> [[$reports->{2}:$reports->{3}]] ($AtoB%/$BtoA%/$ratio%)";
                        $kernel->post( $sender => privmsg => $settings{StatsChannel} => "* $counter $outputtext - ($reports->{6})" );
                        $reports->{6} =~ s/\s//g;
                        $report .="\r\n# $outputtext - [$reports->{6} diff] - [[User:COIBot/UserReports/$reports->{1}|COIBot UserReport]].";
                        $reporten .="\r\n# $outputtext - [$reports->{6} diff] - [[Wikipedia:WikiProject Spam/UserReports/$reports->{1}|COIBot UserReport]].";
                    }
                    $counter++;
                }
                $report .="\r\n$nickname reported $coicounter links.";
                $reporten .="\r\n$nickname reported $coicounter links.";
                $editor->edit("User:COIBot/LinkReports/$toreport","Report on $toreport",$report);
                $eneditor->edit("Wikipedia:WikiProject Spam/LinkReports/$toreport","Report on $toreport",$reporten);
                ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time);
                $year = 1900 + $yearOffset;
                if (length("$hour") == 1) {
                    $hour = "0$hour";
                }
                if (length("$minute") == 1) {
                    $minute = "0$minute";
                }
                if (length("$second") == 1) {
                    $second = "0$second";
                }
                if (length("$dayOfMonth") == 1) {
                    $dayOfMonth = "0$dayOfMonth";
                }
                $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
                $report=$editor->grab_text("User:COIBot/LinkReports");
                $report .= "* $theTime - [[User:COIBot/LinkReports/$toreport]] - [[User talk:COIBot/LinkReports/$toreport]]";
                $editor->edit("User:COIBot/LinkReports","Report created in [[user:COIBot/LinkReports/$toreport]]",$report);
                $report=$eneditor->grab_text("Wikipedia:WikProject Spam/LinkReports");
                $report .= "* $theTime - [[Wikipedia:WikiProject Spam/LinkReports/$toreport]] - [[Wikipedia talk:WikiProject Spam:COIBot/LinkReports/$toreport]]";
                $eneditor->edit("Wikipedia:WikiProject Spam/LinkReports","Report created in [[Wikipedia:WikiProject Spam/LinkReports/$toreport]]",$report);
                $kernel->post( $sender => privmsg => $settings{StatsChannel} => "$coicounter hits on $toreport reported (see [[m:User:COIBot/LinkReports/$toreport]] & [[Wikipedia:Wikiproject Spam/LinkReports/$toreport]])." );
            }
        }

        if ($checkmessage=~m/^report user (.+)/) {                          # ask for a report on a user
            @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
            @weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
            $toreport = $1;
            $coicounter = 0;
            @reports = get_mysql('report','user',$toreport);
            if (@reports) {
                if (@reports[0]->{1} == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error occured in report retrieval.\n" );
                } else {
                    $report = "";
                    foreach $reports(@reports) {
                        $coicounter++;
                        $toreport = $reports->{1};
                    }
                }
            }
            if ($coicounter == 0) {
                $kernel->post( $sender => privmsg => $channel => "No records on [[user:$toreport]]; nothing to report." );
            } else {
                @blacklist = get_mysql('blacklist','user',$toreport);
                if (@blacklist) {
                    if (@blacklist[0]->{1} == -1) {
                        print( "Error occured in blacklist retrieval.\n" );
                        @blacklist = ();
                    }
                }
                @whitelist = get_mysql('whitelist','user',$toreport);
                if (@whitelist) {
                    if (@whitelist[0]->{1} == -1) {
                        print( "Error occured in whitelist retrieval.\n" );
                        @whitelist = ();
                    }
                }
                $kernel->post( $sender => privmsg => $channel => "Reporting COI statistics of [[user:$toreport]] to $settings{StatsChannel}; $coicounter records (see [[m:User:COIBot/UserReports/$toreport]])." );
                $report = "Reporting statistics of [[user:$toreport]]; $coicounter records.";
                $reporten = "Reporting COI statistics of [[user:$toreport]]; $coicounter records.";
                if (@blacklist) {
                    $report .= "\r\n* Blacklist search for user $toreport gives: ";
                    $reporten .= "\r\n* Blacklist search for user $toreport gives: ";
                    foreach $blacklist(@blacklist) {
                      $report .= "\r\n:* $blacklist->{1} ($blacklist->{3})";
                      $reporten .= "\r\n:* $blacklist->{1} ($blacklist->{3})";
                    }
                }
                if (@whitelist) {
                    $report .= "\r\n* Whitelist search for user $toreport gives:";
                    $reporten .= "\r\n* Whitelist search for user $toreport gives:";
                    foreach $whitelist(@whitelist) {
                      $report .= "\r\n:* $whitelist->{1} ($whitelist->{3})";
                      $reporten .= "\r\n:* $whitelist->{1} ($whitelist->{3})";
                    }
                }
                $report .= "\r\n\r\nReports";
                $reporten .= "\r\n\r\nReports";
                $kernel->post( $sender => privmsg => $settings{StatsChannel} => "Reporting COI statistics of [[user:$toreport]]; $coicounter records." );
                $AtoB = 0;
                $BtoA = 0;
                $ratio = 0;
                $theTime="";
                $outputtext = "";
                $url1 = "";
                $page1 = "";
                $counter = 1;
                foreach $reports(@reports) {    #username, language, page, url,fullurl, diff, time
                    ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime($reports->{7});
                    $year = 1900 + $yearOffset;
                    if (length("$hour") == 1) {
                        $hour = "0$hour";
                    }
                    if (length("$minute") == 1) {
                        $minute = "0$minute";
                    }
                    if (length("$second") == 1) {
                        $second = "0$second";
                    }
                    if (length("$dayOfMonth") == 1) {
                        $dayOfMonth = "0$dayOfMonth";
                    }
                    $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
                    $user1 = $reports->{1};
                    $url1=lc($reports->{4});
                    $page1=$reports->{3};
                    if (length($reports->{5}) > 0 ) {
                        ($url1,$garbage) = split (/\//, $url1,2);
                        $url1 =~ s/www//s;
                        $url1 =~ s/www3\.//s;
                        $url1 =~ s/\.//s;                                       #username, language, page, url, fullurl, diff, time
                        $AtoB = weighing($user1,$url1);
                        $BtoA = weighing($url1,$user1);
                        $ratio = int(($AtoB * $BtoA)/10)/10;
                        $outputtext = "$theTime [[$reports->{2}:user:$reports->{1}]] <-> $reports->{4} ($AtoB%/$BtoA%/$ratio%) - [[$reports->{2}:$reports->{3}]]";
                        $kernel->post( $sender => privmsg => $settings{StatsChannel} => "* $counter $outputtext - ($reports->{6})" );
                        $reports->{6} =~ s/\s//g;
                        $report .="\r\n# $outputtext - [$reports->{6} diff] - [[User:COIBot/LinkReports/$reports->{4}|COIBot LinkReport]] - [[Wikipedia:WikiProject_Spam/LinkSearch/$reports->{4}|Link report]] - [http://tools.wikimedia.de/~eagle/linksearch?search=$reports->{4} Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$reports->{4} Eagle's Spamsearch].";
                        $reporten .="\r\n# $outputtext - [$reports->{6} diff] - [[Wikipedia:WikiProject Spam/LinkReports/$reports->{4}|COIBot LinkReport]] - [[Wikipedia:WikiProject_Spam/LinkSearch/$reports->{4}|Link report]] - [http://tools.wikimedia.de/~eagle/linksearch?search=$reports->{4} Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$reports->{4} Eagle's Spamsearch].";
                    } else {                    
                        $AtoB = weighing($user1,$page1);
                        $BtoA = weighing($page1,$user1);
                        $ratio = int(($AtoB * $BtoA)/10)/10;
                        $outputtext = "$theTime [[$reports->{2}:user:$reports->{1}]] <-> [[$reports->{2}:$reports->{3}]] ($AtoB%/$BtoA%/$ratio%)";
                        $kernel->post( $sender => privmsg => $settings{StatsChannel} => "* $counter $outputtext - $reports->{6}" );
                        $reports->{6} =~ s/\s//g;
                        $report .="\r\n# $outputtext - [$reports->{6} diff].";
                        $reporten .="\r\n# $outputtext - [$reports->{6} diff].";
                    }
                    $counter++;
                }
                $report .="\r\n$nickname reported $coicounter additions by [[user:$toreport]] reported.";
                $editor->edit("User:COIBot/UserReports/$toreport","Report on $toreport",$report);
                $eneditor->edit("Wikipedia:WikiProject Spam/UserReports/$toreport","Report on $toreport",$reporten);
                ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time);
                $year = 1900 + $yearOffset;
                if (length("$hour") == 1) {
                    $hour = "0$hour";
                }
                if (length("$minute") == 1) {
                    $minute = "0$minute";
                }
                if (length("$second") == 1) {
                    $second = "0$second";
                }
                if (length("$dayOfMonth") == 1) {
                    $dayOfMonth = "0$dayOfMonth";
                }
                $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
                $report=$editor->grab_text("User:COIBot/UserReports");
                $report .= "* $theTime - [[User:COIBot/UserReports/$toreport]] - [[User talk:COIBot/UserReports/$toreport]]";
                $editor->edit("User:COIBot/UserReports","Report created in [[user:COIBot/UserReports/$toreport]]",$report);
                $report=$eneditor->grab_text("Wikipedia:WikiProject Spam/UserReports");
                $report .= "* $theTime - [[Wikipedia:WikiProject Spam/UserReports/$toreport]] - [[Wikipedia talk:WikiProject Spam/UserReports/$toreport]]";
                $eneditor->edit("Wikipedia:WikiProject Spam/UserReports","Report created in [[Wikipedia:WikiProject Spam/UserReports/$toreport]]",$report);
                $kernel->post( $sender => privmsg => $settings{StatsChannel} => "$coicounter additions by [[user:$toreport]] reported (see [[User:COIBot/UserReports/$toreport]] & [[Wikipedia:WikiProject Spam/UserReports/$toreport]])." );
            }
        }

        if ($checkmessage=~m/^report (\d+)/) {                                  # ask for last reports
            @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
            @weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
            $numbertoreport = $1;
            if ($numbertoreport > $settings{MaxToReport}) {
                $kernel->post( $sender => privmsg => $channel => "Get the fuck out of here, I'll do the last $settings{MaxToReport}." );
                $numbertoreport = $settings{MaxToReport};
            }
            $coicounter = 0;
            @reports = get_mysql('report','user','*');
            if (@reports) {
                if (@reports[0]->{1} == -1 ) {
                    $kernel->post( $sender => privmsg => $channel => "Error occured in report retrieval.\n" );
                } else {
                    foreach $reports(@reports) {
                        $coicounter++;
                    }
                    if ($numbertoreport > $coicounter ) { 
                        $numbertoreport = $coicounter;
                    }
                }
            }
            if ($coicounter == 0) {
                $kernel->post( $sender => privmsg => $channel => "No records found.");
            } else {
                $kernel->post( $sender => privmsg => $channel => "Reporting $numbertoreport records to $settings{StatsChannel}." );
                $kernel->post( $sender => privmsg => $settings{StatsChannel} => "Reporting $numbertoreport records." );
                $counter = 0;
                $AtoB = 0;
                $BtoA = 0;
                $ratio=0;
                for ($counter=0;$counter<$numbertoreport;$counter++) {    #username, language, page, fullurl, diff, time
                    ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime($reports[$counter]->{6});
                    $year = 1900 + $yearOffset;
                    if (length("$hour") == 1) {
                        $hour = "0$hour";
                    }
                    if (length("$minute") == 1) {
                        $minute = "0$minute";
                    }
                    if (length("$second") == 1) {
                        $second = "0$second";
                    }
                    if (length("$dayOfMonth") == 1) {
                        $dayOfMonth = "0$dayOfMonth";
                    }
                    $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
                    $user1 = $reports[$counter]->{1};
                    if (length($reports[$counter]->{4}) > 0 ) {
                        $url1=lc($reports[$counter]->{4});
                        ($url1,$garbage) = split (/\//, $url1,2);
                        $url1 = lc($url1);
                        $url1 =~ s/www//s;
                        $url1 =~ s/www3\.//s;
                        $url1 =~ s/\.//s;
                        $AtoB = weighing($user1,$url1);
                        $BtoA = weighing($url1,$user1);
                        $ratio = int(($AtoB * $BtoA)/10)/10;
                        $kernel->post( $sender => privmsg => $settings{StatsChannel} => "* $counter $theTime [[$reports[$counter]->{2}:user:$reports[$counter]->{1}]] <-> [http://$reports[$counter]->{4}] ($AtoB%/$BtoA%/$ratio%) - [[$reports[$counter]->{2}:$reports[$counter]->{3}]] - $reports[$counter]->{5}" );
                    } else {                    
                        $page1=$reports[$counter]->{3};
                        $AtoB = weighing($user1,$page1);
                        $BtoA = weighing($page1,$user1);
                        $ratio = int(($AtoB * $BtoA)/10)/10;
                        $kernel->post( $sender => privmsg => $settings{StatsChannel} => "* $counter $theTime [[$reports[$counter]->{2}:user:$reports[$counter]->{1}]] <-> [[$reports[$counter]->{2}:$reports[$counter]->{3}]] ($AtoB%/$BtoA%/$ratio%) - $reports[$counter]->{5}" );
                    }
                }
                $kernel->post( $sender => privmsg => $settings{StatsChannel} => "$numbertoreport records reported." );
            }
        }

        if ($checkmessage=~m/^reportlevel (\d+)/ || $checkmessage=~m/^lwreportlevel (\d+)/) {                             # set reportlevel
            $reportlevel = $1;                                               #  0 -> silence
            $verified = 0;                                                   #  1 -> short reports, first && every #
            $verified=authenticate($cloak);                                     #  2 -> short reports, every addition
            if ($verified == 1) {                                               #  3 -> long reports, first && every #
                $settings{LWReportLevel} = $reportlevel;                          #  4 -> long reports, every addition
                if ($settings{LWReportLevel} > 4) {                               #  (every # is defined by report every)
                    $settings{LWReportLevel} = 4;
                }
                if ($settings{LWReportLevel} < 0) {
                    $settings{LWReportLevel} = 0;
                }
                $kernel->post( $sender => privmsg => $channel => "Reporting to $settings{ReportChannel1} (limited) && $settings{ReportChannel2} (all); report level for linkwatcher is $settings{LWReportLevel}."); 
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^rcreportlevel (\d+)/ ) {                             # set reportlevel
            $reportlevel = $1;                                               #  0 -> silence
            $verified = 0;                                                   #  1 -> short reports, first && every #
            $verified=authenticate($cloak);                                     #  2 -> short reports, every addition
            if ($verified == 1) {                                               #  3 -> long reports, first && every #
                $settings{RCReportLevel} = $reportlevel;                          #  4 -> long reports, every addition
                if ($settings{RCReportLevel} > 4) {                               #  (every # is defined by report every)
                    $settings{RCReportLevel} = 4;
                }
                if ($settings{RCReportLevel} < 0) {
                    $settings{RCReportLevel} = 0;
                }
                $kernel->post( $sender => privmsg => $channel => "Reporting to $settings{ReportChannel1} (limited) && $settings{ReportChannel2} (all); report level for RC-watcher is $settings{RCReportLevel}."); 
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^deteriorate (\d+)/) {                             # set deterioration
            $deterioration = $1/100;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $settings{deterioration} = $deterioration;
                $kernel->post( $sender => privmsg => $channel => "Deterioration set to $settings{deterioration}."); 
            } elsif ($verified == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error retrieving cloaks from MySQL." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~ m/^die/ || $checkmessage=~ m/^quit/ ) {
            print("GOING DOWN!\r\n");
            if (lc($cloak) eq "wikimedia/beetstra" || lc($cloak) eq "wikimedia/versageek") {
                $saveerror = 0;
                if ($checkmessage=~ m/^quit/) {
                    $kernel->post( $sender => privmsg => $channel =>  "Mayday! Mayday! .. going down!");
                } else {
                    $kernel->post( $sender => privmsg => $channel =>  "Und sterb' ich denn, so sterb' ich doch ... Durch sie, durch sie, ...");
                }
                if (length($settings{report}) > 0) {
                    ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time());
                    $year = 1900 + $yearOffset;
                    $today = "$year, $months[$month] $dayOfMonth";
                    $settings{savereport} .= $settings{report};
                    $settings{savereporten} .= $settings{reporten};
                    $settings{savecounter} = $settings{savecounter} + $settings{reportcounter};
                    $settings{savecounteren} = $settings{savecounteren} + $settings{reportencounter};
                    $settings{reportcounter} = 0;
                    $settings{reportencounter} = 0;
                    delete $settings{report};
                    $settings{report} = "";
                    delete $settings{reporten};
                    $settings{reporten} = "";
                    eval {
                        $report2 = $eneditor->grab_text("Wikipedia:WikiProject Spam/COIReports/$today");
                    };
                    if ($@) {
                        $kernel->post( $sender => privmsg => $channel => "ERROR! while reading from to en.wikipedia ($nickname will not quit)." );
                        $saveerror = 1;
                    } else {
                        $report2 .= $settings{savereporten};
                        $report2 =~ s/amp;//g;
                        eval {
                            $eneditor->edit("Wikipedia:WikiProject Spam/COIReports/$today","$nickname save - $settings{savecounteren} reports (quit).",$report2);
                        };
                        if ($@) {
                            $kernel->post( $sender => privmsg => $channel => "ERROR! while saving to en.wikipedia ($nickname will not quit)." );
                            $saveerror = 0;
                        } else {
                            $kernel->post( $sender => privmsg => $channel => "Saved to en.wikipedia (quit)." );
                            delete $settings{savereporten};
                            $settings{savereporten} = "";
                            $settings{savecounteren} = 0;
                        }
                    }
                    eval {
                        $report2 = $editor->grab_text("User:COIBot/COIReports/$today");
                    };
                    if ($@) {
                        $kernel->post( $sender => privmsg => $channel => "ERROR! While reading from to meta.wikimedia." );
                        $saveerror = 1;
                    } else {
                        $report2 .= $settings{savereport};
                        $report2 =~ s/amp;//g;
                        eval {
                            $editor->edit("User:COIBot/COIReports/$today","$nickname save - $settings{savecounter} reports (quit).",$report2);
                        };
                        if ($@) {
                            $kernel->post( $sender => privmsg => $channel => "ERROR! While saving to meta.wikimedia." );
                            $saveerror = 1;
                        } else {
                            $kernel->post( $sender => privmsg => $channel => "Saved to meta.wikimedia (quit)." );
                            delete $settings{savereport};
                            $settings{savereport} ="";
                            $settings{savecounter} = 0;
                        }
                    }
                } 
                if ($saveerror == 0) {
                    if ($checkmessage=~ m/^quit/) {
                        $kernel->signal($kernel, 'POCOIRC_SHUTDOWN', "Mayday! Mayday! .. going down!");
                    } else {
                        $kernel->signal($kernel, 'POCOIRC_SHUTDOWN', "Und sterb' ich denn, so sterb' ich doch ... Durch sie, durch sie, ...");
                    }
                }
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "Only Dirk Beetstra && Versageek can tell me to quit." );
            }
        }

        if ($checkmessage=~m/^limit (\d+)/) {
            $limit = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $settings{limit} = int( 100 *  $limit / 100 ) ;
                if ($settings{limit}<1) {
                    $settings{limit} = 1;
                }
                $kernel->post( $sender => privmsg => $channel => "Yes master! My new limit is $settings{limit}");
            } elsif ($verified == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error retrieving cloaks from MySQL." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^interval (\d+)/) {
            $limit = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $settings{interval} = int( 100 *  $limit / 100 ) ;
                if ($settings{interval}<300) {
                    $settings{interval} = 300;
                }
                $kernel->post( $sender => privmsg => $channel => "Yes master! My new interval is $settings{interval}");
            } elsif ($verified == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error retrieving cloaks from MySQL." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^savelimit (\d+)/) {
            $limit = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $settings{reportmax} = $limit;
                if ($settings{reportmax}<10) {
                    $settings{reportmax} = 10;
                    $kernel->post( $sender => privmsg => $channel => "");
                }
                $kernel->post( $sender => privmsg => $channel => "Yes master! I will now save after every $settings{reportmax} reports");
            } elsif ($verified == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error retrieving cloaks from MySQL." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~ m/^save$/) {
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                if (length($settings{report}) > 0) {
                    ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time());
                    $year = 1900 + $yearOffset;
                    $today = "$year, $months[$month] $dayOfMonth";
                    $settings{savereport} .= $settings{report};
                    $settings{savereporten} .= $settings{reporten};
                    $settings{savecounter} = $settings{savecounter} + $settings{reportcounter};
                    $settings{savecounteren} = $settings{savecounter} + $settings{reportencounter};
                    $settings{reportcounter} = 0;
                    delete $settings{report};
                    $settings{report} = "";
                    delete $settings{reporten};
                    $settings{reporten} = "";
                    eval {
                        $report2 = $eneditor->grab_text("Wikipedia:WikiProject Spam/COIReports/$today");
                    };
                    if ($@) {
                        $kernel->post( $sender => privmsg => $channel => "ERROR! while reading from to en.wikipedia." );
                    } else {
                        $report2 .= $settings{savereporten};
                        $report2 =~ s/amp;//g;
                        eval {
                            $eneditor->edit("Wikipedia:WikiProject Spam/COIReports/$today","$nickname save - $settings{savecounteren} reports(forced save).",$report2);
                        };
                        if ($@) {
                            $kernel->post( $sender => privmsg => $channel => "ERROR! while saving to en.wikipedia." );
                        } else {
                            $kernel->post( $sender => privmsg => $channel => "Saved to en.wikipedia (forced save)." );
                            delete $settings{savereporten};
                            $settings{savereporten} = "";
                            $settings{savecounteren} = 0;
                        }
                    }
                    eval {
                        $report2 = $editor->grab_text("User:COIBot/COIReports/$today");
                    };
                    if ($@) {
                        $kernel->post( $sender => privmsg => $channel => "ERROR! While reading from to meta.wikimedia." );
                    } else {
                        $report2 .= $settings{savereport};
                        $report2 =~ s/amp;//g;
                        eval {
                            $editor->edit("User:COIBot/COIReports/$today","$nickname save - $settings{savecounter} reports (forced save).",$report2);
                        };
                        if ($@) {
                            $kernel->post( $sender => privmsg => $channel => "ERROR! While saving to meta.wikimedia." );
                        } else {
                            $kernel->post( $sender => privmsg => $channel => "Saved to meta.wikimedia (forced save)." );
                            delete $settings{savereport};
                            $settings{savereport} ="";
                            $settings{savecounter} = 0;
                        }
                    }
                }
            } elsif ($verified == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error retrieving cloaks from MySQL." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^shut up/) {
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $settings{LWReportLevel} = 0;
                $settings{RCReportLevel} = 0;
                $kernel->post( $sender => privmsg => $channel => "Why are you so unfriendly to me .. *snif*, but OK, I'll keep quiet. (report level is $settings{LWReportLevel} (LW) && $settings{LWReportLevel} (RC))."); 
            } elsif ($verified == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error retrieving cloaks from MySQL." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^lookbacktime (\d+)/) {
            $lookbacktime = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $settings{lookbacktime} = int( 100 *  $1 / 100 ) ;
                if ($settings{lookbacktime}<1) {
                    $settings{lookbacktime} = 1;
                }
                $kernel->post( $sender => privmsg => $channel => "Yes master! My new lookback time is $settings{lookbacktime}");
            } elsif ($verified == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error retrieving cloaks from MySQL." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^report every (\d+)/) {
            $reportevery = "";
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $settings{ReportEvery} = int( 100 *  $reportevery / 100 ) ;
                if ($settings{ReportEvery}<2) {
                    $settings{ReportEvery} = 5;
                }
                $kernel->post( $sender => privmsg => $channel => "Yes master! I now report the first && every $settings{ReportEvery} addition");
            } elsif ($verified == -1) {
                    $kernel->post( $sender => privmsg => $channel => "Error retrieving cloaks from MySQL." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage=~m/^test (.+)/) {
            ($user,$strng) = split(/\s/,$1,2);
            $AtoB = weighing(lc($user),lc($strng));
            $BtoA = weighing(lc($strng),lc($user));
            $ratio = int( $AtoB * $BtoA) / 100;
            $kernel->post( $sender => privmsg => $channel => "TEST: [[en:User:$user]]/[[en:Special:Contributions/$user]] scores $AtoB% (U->T) && $BtoA% (T-U) (ratio $ratio%) on string $strng");
        }

        if ($checkmessage=~m/^links (.+)/) {
            ($name,$exte) = split(/\./,$1,2);
            if (length($exte) == 0) { 
                $exte = '.com'; 
            }
            $kernel->post( $sender => privmsg => $channel => "Links: [[en:User:$name]] - [[en:User talk:$name]] - [[en:Special:Contributions/$name]] - [[en:$name]] - [[special:linksearch/$name.$exte]] - [http://www.$name.$exte]");
        }

        if ($checkmessage =~ m/^bl add (.+)/ ) {
            ($garbage,$garbage,$user,$strng,$reason) = split(/\s/,$message,5);
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                if (length($reason) == 0) {
                    $kernel->post( $sender => privmsg => $channel => "You have not provided a reason (format: $nickname bl add user string reason).");
                } else {
                    $exists=check_mysql("blacklist",$user,$strng);
                    if ($exists == 1) {
                        $kernel->post( $sender => privmsg => $channel => "Sorry! The link '$user' <-> '$strng' is already on my blacklist!");
                    } elsif ($exists == -1) {
                        $kernel->post( $sender => privmsg => $channel => "MySQL while checking item on blacklist.");
                    } elsif ($exists == 0) {
                        $result = add_mysql("blacklist",$user,$strng,$reason);
                        if ($result == -1) {
                            $kernel->post( $sender => privmsg => $channel => "MySQL error while adding item.");
                        } else {
                            $kernel->post( $sender => privmsg => $channel => "OK! The link '$user' <-> '$strng' has been added to my blacklist ($reason).");
                        }
                    }
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage =~ m/^bl remove (.+)/ || $checkmessage =~ m/^bl del (.+)/) {
            ($user,$strng) = split(/\s/,$1,2);
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $exists=check_mysql('blacklist',lc($user),lc($strng));
                if ($exists == 0) {
                    $kernel->post( $sender => privmsg => $channel => "Sorry! The link '$user' <-> '$strng' is not on my blacklist!");
                } elsif ($exists == -1) {
                    $kernel->post( $sender => privmsg => $channel => "MySQL while checking item on blacklist.");
                } elsif ($exists == 1) {
                    $result = delete_mysql("blacklist",lc($user),lc($strng));
                    if ($result) {
                        $kernel->post( $sender => privmsg => $channel => "MySQL error while deleting item.");
                    } else {
                        $kernel->post( $sender => privmsg => $channel => "OK! The link '$user' <-> '$strng' has been added to my blacklist.");
                    }
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage =~ m/^bl search (.+)/ ) {
            ($user,$strng) = split(/\s/,$1,2);
            if ($user eq 'user') {
                @arr = get_mysql('blacklist','user',lc($strng));
                if (@arr) {
                    if (@arr[0]->{1} == -1) {
                    } else {
                        $outstring = "";
                        $outstring = "Yes, User $strng is on my blacklist! ";
                        $outstring .= "Linked to: ";
                        foreach $arr(@arr) {
                            $outstring .= "[$arr->{1}] ";
                        }
                        $kernel->post( $sender => privmsg => $channel => $outstring);
                    }
                } else {
                    $kernel->post( $sender => privmsg => $channel => "Nope! User '$strng' does not appear on my blacklist.");
                }
            } elsif ($user eq 'string' || $user eq 'link') {
                @arr = get_mysql('blacklist','string',lc($strng));
                if (@arr) {
                    if (@arr[0]->{1} == -1) {
                    } else {
                        $outstring = "";
                        $outstring = "Yes, $strng is in my blacklist! ";
                        $outstring .= "String [$strng] is linked to: ";
                        foreach $arr(@arr) {
                            $outstring .= "$arr->{1} ";
                        }
                        $kernel->post( $sender => privmsg => $channel => $outstring);
                    }
                } else {
                    $kernel->post( $sender => privmsg => $channel => "Nope! The text '$strng' does not appear on my blacklist.");
                }
            } else {
                $exists=check_mysql('blacklist',$user,lc($strng));
                if ($exists ==0) {
                    $kernel->post( $sender => privmsg => $channel => "Nope! Link '$user' <-> '$strng' does not appear in my blacklist." );
                }
                if ($exists ==-1) {
                    $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
                }
                if ($exists == 1) {
                    $kernel->post( $sender => privmsg => $channel => "Yes! The link '$user' <-> '$strng' was found on my blacklist.");
                }
            }
        }

        if ($checkmessage =~ m/^wl add (.+)/ ) {
            ($garbage,$garbage,$user,$strng,$reason) = split(/\s/,$message,5);
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                if (length($reason) == 0) {
                    $kernel->post( $sender => privmsg => $channel => "You have not provided a reason (format: $nickname wl add user string reason).");
                } else {
                    $exists=check_mysql("whitelist",$user,$strng);
                    if ($exists == 1) {
                        $kernel->post( $sender => privmsg => $channel => "Sorry! The link '$user' <-> '$strng' is already on my whitelist!");
                    } elsif ($exists == -1) {
                        $kernel->post( $sender => privmsg => $channel => "MySQL error while checking item on whitelist.");
                    } elsif ($exists == 0) {
                        $result = add_mysql("whitelist",$user,$strng,$reason);
                        if ($result == -1) {
                            $kernel->post( $sender => privmsg => $channel => "MySQL error while adding item.");
                        } else {
                            $kernel->post( $sender => privmsg => $channel => "OK! The link '$user' <-> '$strng' has been added to my whitelist ($reason).");
                        }
                    }
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage =~ m/^wl remove (.+)/ || $checkmessage =~ m/^wl del (.+)/) {
            ($user,$strng) = split(/\s/,$1,2);
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $exists=check_mysql('whitelist',lc($user),lc($strng));
                if ($exists == 0) {
                    $kernel->post( $sender => privmsg => $channel => "Sorry! The link '$user' <-> '$strng' is not on my whitelist!");
                } elsif ($exists == -1) {
                    $kernel->post( $sender => privmsg => $channel => "MySQL error while checking item on whitelist.");
                } elsif ($exists == 1) {
                    $result = delete_mysql("whitelist",lc($user),lc($strng));
                    if ($result) {
                        $kernel->post( $sender => privmsg => $channel => "MySQL error while deleting item.");
                    } else {
                        $kernel->post( $sender => privmsg => $channel => "OK! The link '$user' <-> '$strng' has been added to my whitelist.");
                    }
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage =~ m/^wl search (.+)/ ) {
            ($user,$strng) = split(/\s/,$1,2);
            if ($user eq 'user') {
                @arr = get_mysql('whitelist','user',lc($strng));
                if (@arr) {
                    if (@arr[0]->{1} == -1) {
                    } else {
                        $outstring = "";
                        $outstring = "Yes, User '$strng' is on my whitelist! ";
                        $outstring .= "Linked to: ";
                        foreach $arr(@arr) {
                            $outstring .= "[$arr->{1}] ";
                        }
                        $kernel->post( $sender => privmsg => $channel => $outstring);
                    }
                } else {
                    $kernel->post( $sender => privmsg => $channel => "Nope! User '$strng' does not appear on my whitelist.");
                }
            } elsif ($user eq 'string' || $user eq 'link') {
                @arr = get_mysql('whitelist','string',lc($strng));
                if (@arr) {
                    if (@arr[0]->{1} == -1) {
                    } else {
                        $outstring = "";
                        $outstring = "Yes, The text '$strng' is on my whitelist! ";
                        $outstring .= "Linked to: ";
                        foreach $arr(@arr) {
                            $outstring .= "$arr->{1} ";
                        }
                        $kernel->post( $sender => privmsg => $channel => $outstring);
                    }
                } else {
                    $kernel->post( $sender => privmsg => $channel => "Nope! The text '$strng' does not appear on my whitelist.");
                }
            } else {
                $exists=check_mysql('whitelist',lc($user),lc($strng));
                if ($exists ==0) {
                    $kernel->post( $sender => privmsg => $channel => "Nope! Link '$user' <-> '$strng' does not appear in my whitelist." );
                }
                if ($exists ==-1) {
                    $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
                }
                if ($exists == 1) {
                    $kernel->post( $sender => privmsg => $channel => "Yes! The link '$user' <-> '$strng' was found on my whitelist.");
                }
            }
        }

        if ($checkmessage =~ m/^ml add (.+)/ ) {
            $strng = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $exists=check_mysql("monitor",lc($strng));
                if ($exists == 1) {
                    $kernel->post( $sender => privmsg => $channel => "Sorry! The text '$strng' is already on my list of text to monitor");
                } elsif ($exists == -1) {
                    $kernel->post( $sender => privmsg => $channel => "MySQL error while checking item on monitor list.");
                } elsif ($exists == 0) {
                    $result = add_mysql("monitor",lc($strng));
                    if ($result == -1) {
                        $kernel->post( $sender => privmsg => $channel => "MySQL error while adding item.");
                    } else {
                        $kernel->post( $sender => privmsg => $channel => "OK! The text '$strng' is added to the list of text to monitor.");
                    }
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage =~ m/^ml remove (.+)/ || $checkmessage =~ m/^ml del (.+)/) {
            $strng = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $exists=check_mysql("monitor",lc($strng));
                if ($exists == 0) {
                    $kernel->post( $sender => privmsg => $channel => "Sorry! The text '$strng' does not appear on my list of strings to monitor." );
                } elsif ($exists == -1) {
                    $kernel->post( $sender => privmsg => $channel => "MySQL error while checking item on monitor list.");
                } elsif ($exists == 1) {
                    $result = delete_mysql("monitor",lc($strng));
                    if ($result) {
                        $kernel->post( $sender => privmsg => $channel => "MySQL error while deleting item.");
                    } else {
                        $kernel->post( $sender => privmsg => $channel => "OK! String '$strng' has been removed from my list of links to monitor.");
                    }
                }
            } elsif ($verified == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL retrieval error occured, please try again." );
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "User $nick is not on my list of trusted users." );
            }
        }

        if ($checkmessage =~ m/^ml search (.+)/ ) {
            $strng = $1;
            $exists=check_mysql('monitor',lc($strng));
            if ($exists == -1) {
                $kernel->post( $sender => privmsg => $channel => "MySQL error while checking item on monitor list.");
            } elsif ($exists == 1) {
                $kernel->post( $sender => privmsg => $channel => "Yes! '$strng' was found on my monitor list.");
            } else {
                $kernel->post( $sender => privmsg => $channel => "Nope! '$strng' was not found on my monitor list." );
            }
        }

        if ($checkmessage =~ m/^add trusted (.+)/ ) {
            $totrust = $1;
            if ($cloak eq 'Wikimedia/Beetstra') {
                $exists=check_mysql("trusted_users",$totrust);
                if ($exists == 1) {
                    $kernel->post( $sender => privmsg => $channel =>  "User $totrust is already in my list of trusted users.");
                } elsif ($exists == -1) {
                    $kernel->post( $sender => privmsg => $channel => "MySQL error while checking item on monitor list.");
                } else {
                    $result = add_mysql("trusted_users",$totrust);
                    if ($result == -1) {
                        $kernel->post( $sender => privmsg => $channel =>  "MySQL error while adding item.");
                    } else {
                        $kernel->post( $sender => privmsg => $channel =>  "User $totrust has been added to my list of trusted users.");
                    }
                }
            } else {
                $kernel->post( $sender => privmsg => $channel => "Action restricted to Bot operator (Dirk Beetstra)." );
            }
        }

        if ($checkmessage =~ m/^del trusted (.+)/ || $checkmessage =~ m/^remove trusted (.+)/) {
            $totrust = $1;
            if ($cloak eq 'Wikimedia/Beetstra') {
                $exists=check_mysql("trusted_users",$totrust);
                if ($exists == 1) {
                    $kernel->post( $sender => privmsg => $channel =>  "User $totrust is already in my list of trusted users.");
                } elsif ($exists == -1) {
                    $kernel->post( $sender => privmsg => $channel => "MySQL error while checking item on monitor list.");
                } else {
                    $result = del_mysql("trusted_users",$totrust);
                    if ($result == -1) {
                        $kernel->post( $sender => privmsg => $channel =>  "MySQL error while removing item.");
                    } else {
                        $kernel->post( $sender => privmsg => $channel =>  "User $totrust has been added to my list of trusted users.");
                    }
                }
            } else {
                $kernel->post( $sender => privmsg => $channel => "Action restricted to Bot operator (Dirk Beetstra)." );
            }
        }

        if ($checkmessage=~m/^help$/) {
            $totrust = $1;
            $verified = 0;
            $verified=authenticate($cloak);
            if ($verified == 1) {
                $kernel->post( $sender => privmsg => $channel => "$nick is on trusted user list(*); comm&&s: status; bl & wl search [user] [string]; ml search [string]; channels; test [user] [string]; report user [name]; report link [string]; report #; *quit; *limit {0-100}; *bl & *wl add/remove [user] [string]; *ml add/remove [string]; *reportlevel {0-4}; *report every #; *deteriorate; *lookbacktime; *join (rc/lw)channel [channel]; *part (rc/lw)channel [channel]; *save; *savelimit");
            } elsif ($verified == 0) {
                $kernel->post( $sender => privmsg => $channel => "$nick is not on trusted users list; comm&&s: status; bl & wl search [user] [string]; rcchannels; test [user] [string]; report user [name]; report #");
            }
        }

        if ($checkmessage=~m/^help bl$/ || $checkmessage=~m/^help wl/) {
            $kernel->post( $sender => privmsg => $channel => "comm&&s '$nickname bl/wl add [user] [string] (restricted)', '$nickname bl/wl remove [user] [string]' (restricted), '$nickname bl/wl search [user] [string]', '$nickname bl/wl search user [user]', '$nickname bl/wl search string [string]' ");
        }

        if ($checkmessage=~m/^help bl add$/ || $checkmessage=~m/^help wl add/) {
            $kernel->post( $sender => privmsg => $channel => "comm&&s '$nickname bl/wl add [user] [string]' (restricted): adds link between [user] && [string] (replace spaces with underscore)");
        }

        if ($checkmessage=~m/^help bl remove$/ || $checkmessage=~m/^help wl remove/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname bl/wl remove [user] [string]' (restricted): remove link between [user] && [string] (replace spaces with underscore)");
        }

        if ($checkmessage=~m/^help bl search$/ || $checkmessage=~m/^help wl search/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname bl/wl search ..'; search for connection: '[user] [string]'; search all strings connected to user: 'user [user]'; search all users connected to string: 'string [string]' (replace spaces with underscore)");
        }

        if ($checkmessage=~m/^help ml$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&&s '$nickname ml add [string] (restricted)', '$nickname ml remove [string]' (restricted), '$nickname ml search [string]' ");
        }

        if ($checkmessage=~m/^help ml add$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&&s '$nickname ml add [string]' (restricted): adds string (domain without www) to monitor list.");
        }

        if ($checkmessage=~m/^help ml remove$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname ml remove [string]' (restricted): remove string (domain without www) from monitor list.");
        }

        if ($checkmessage=~m/^help ml search$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname ml search [string]'; search for occurance of string on monitor list");
        }

        if ($checkmessage=~m/^help add trusted$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname add trusted [cloak]': adds a cloak to the list of trusted users.");
        }

        if ($checkmessage=~m/^help remove trusted$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname remove trusted [cloak]': remove a cloak from the list of trusted users.");
        }

        if ($checkmessage=~m/^help links$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname links [string]': prints a list of links to various places in wiki && outside wiki.");
        }

        if ($checkmessage=~m/^help test$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname test [string1] [string2]': Overlap test between the two strings (same mechanism as coi-recognition).");
        }

        if ($checkmessage=~m/^help lookbacktime$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname lookbacktime [#]': Time $nickname looks back to see whether a user has been reported before.");
        }

        if ($checkmessage=~m/^help limit$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname limit {0-100}': $nickname reports overlap when overlap exceeds the limit.");
        }

        if ($checkmessage=~m/^help reportlevel$/ || $checkmessage=~m/^help lwreportlevel$/ || $checkmessage=~m/^help rcreportlevel$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname (rc/lw)reportlevel {0-4}': reports to reportchannel: 0 - no output; 1 - short notice first && every n-th; 2 - short notice; 3 - full report first && every n-th; 4 - full report.");
        }

        if ($checkmessage=~m/^help report$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname report [#]': reports to statistics channel # last reports (use 'help report user' for userreport or 'help report link' for linkreport.");
        }

        if ($checkmessage=~m/^help report user$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname report user [user]': reports to statistics channel all reports on user.");
        }

        if ($checkmessage=~m/^help report link$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname report user [user]': reports to statistics channel all reports on user.");
        }

        if ($checkmessage=~m/^help deteriorate$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname deteriorate [#]': Multiplication factor; shorter matches yield lower percentages (st&&ard 90).");
        }

        if ($checkmessage=~m/^help channels$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname channels': lists feed link channels $nickname is reading from (see help join/part channel for joining/parting).");
        }

        if ($checkmessage=~m/^help join channel$/ || $checkmessage=~m/^help join lwchannel$/ || $checkmessage=~m/^help join rcchannel$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname join (rc/lw)channel [channel]': add a feed channel to $nickname's read list (use rcchannel for irc.wikimedia, use channel or lwchannel for linkwatch channels).");
        }

        if ($checkmessage=~m/^help part channel$/ || $checkmessage=~m/^help part lwchannel$/ || $checkmessage=~m/^help part rcchannel$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname part (rc/lw)channel [channel]': part a feed channel (use rcchannel for irc.wikimedia, use channel or lwchannel for linkwatch channels).");
        }

        if ($checkmessage=~m/^help report every$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname report every [#]': Report first && every # addition.");
        }

        if ($checkmessage=~m/^help savelimit$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname savelimit [#]': Write every # to wiki (don't set this too low otherwise bot will flood some channels, thanks).");
        }

        if ($checkmessage=~m/^help save$/) {
            $kernel->post( $sender => privmsg => $channel => "comm&& '$nickname save': Force a save to wiki pages.");
        }
    }
    undef $kernel;
    undef $heap;
    undef $sender;
    undef $who;
    undef $where;
    undef $message;
    undef $nick;
    undef $cloak;
    undef $channel;
    undef $checkmessage;
    undef $message_to_send;
    undef $newchannel;
    undef $verified;
    undef $oldchannel;
    undef $toreport;
    undef @reports;
    undef $coicounter;
    undef $report;
    undef $AtoB;
    undef $BtoA;
    undef $ratio;
    undef $theTime;
    undef $outputtext;
    undef $average;
    undef $poco_object;
    undef $reason;
    undef $alias;
    undef @channels;
    undef $url1;
    undef $page1;
    undef $report2;
    undef $uptime;
    undef $channel2;
    undef $counter;
    undef $today;
    undef $currentreport;
    undef $second;
    undef $minute;
    undef $hour;
    undef $dayOfMonth; 
    undef $reporten;
    undef $month; 
    undef $channels;
    undef $blacklist;
    undef $whitelist;
    undef $yearOffset; 
    undef $dayOfWeek; 
    undef $dayOfYear; 
    undef $daylightSavings;
    undef $user1;
    undef $garbage;
    undef $numbertoreport;
    undef $deterioration;
    undef $limit;
    undef $lookbacktime;
    undef $reportevery;
    undef $user;
    undef $strng;
    undef $exte;
    undef @blacklist;
    undef @whitelist;
    undef $name;
    undef $server;
    undef $result;
    undef $exists;
    undef @arr;
    undef $outstring;
    undef $reports;
    undef $year;
    undef $arr;
    undef $saveerror;
    undef $totrust;
    undef $reportlevel;
    undef $toreport2;
    undef $timedifference;
    undef;
}

sub compareandreport {
    my $channel = shift;
    my $kernel = shift;
    my $sender = shift;
    my $lang = shift;
    my $user = shift;
    my $page = shift;
    my $url = shift;
    my $fullurl = shift;
    my $search = shift;
    my $searchin = shift;
    my $searchfrom = shift;
    my $searchto = shift;
    my $diff = shift;
    my $watcher = shift;
    my $watchlevel;
    my $totalcounter;
    my $counter;
    my $reports;
    my $year;
    my $resulting;
    my $theTime;
    my @reports;
    my $AtoB;
    my $BtoA;
    my $ratio;
    my $exists;
    my $dayOfMonth;
    my $month;
    my $dayOfWeek;
    my $second;
    my $result;
    my $minute;
    my $hour;
    my $yearOffset;
    my $daylightSavings;
    my $dayOfYear;
    $resulting = 0;
    $url = lc($url);
    print("  $lang $user $page $url $fullurl $diff\n");
    print("  Testing $search on $searchin.\n");
    if (($search eq "*") && ($url != "") ) {
        ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time);
        $year = 1900 + $yearOffset;
        if (length($hour) == 1) {
            $hour = "0$hour";
        }
        if (length($minute) == 1) {
            $minute = "0$minute";
        }
        if (length($second) == 1) {
            $second = "0$second";
        }
        if (length($dayOfMonth) == 1) {
            $dayOfMonth = "0$dayOfMonth";
        }
        $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
        $counter = 0;
        $totalcounter = 0;
        @reports = get_mysql('report','user',$user);
        if (@reports) {
            if (@reports[0]->{1} == -1 ) {
                $counter--;
                $totalcounter--;
            } else {
                foreach $reports(@reports) {
                    if ($reports->{7} > (time() - $settings{LookBackTime})) {
                        $counter++;
                    }
                    $totalcounter++;
                }
            }
        }
        $counter++;
        $totalcounter++;
        $settings{reportcounter}++;
        $watchlevel = 0;
        if ($watcher eq "LW") {
            $watchlevel = $settings{LWReportLevel};
            $kernel->post( $settings{reportserver} => privmsg => $channel => "ALERT! Monitored user ($user)! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
        } 
        if ($watcher eq "RC") {
            $watchlevel = $settings{RCReportLevel};
            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ALERT! Monitored user ($user)! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
        }
        print("  Levels: $watcher ; $watchlevel ; LW - $settings{LWReportLevel} ($settings{ReportChannel1}) ; RC $settings{RCReportLevel} ($settings{ReportChannel2})\n");
        if ($lang eq 'en') {
            if ($watchlevel == 1) {
                if ($counter == 1) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored user ($user)! Please check $diff (report $counter/$totalcounter; $settings{reportcounter})");
                } elsif ($counter == $settings{ReportEvery} * int($counter/$settings{ReportEvery})) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored user ($user)! Please check $diff (report $counter/$totalcounter; $settings{reportcounter})");
                }
            }
            if ($watchlevel == 2) {
                $$kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored user ($user)! Please check $diff");
            }
            if ($watchlevel == 3) {
                if ($counter == 1) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored user! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (first report/$totalcounter; $settings{reportcounter})");
                } elsif ($counter == $settings{ReportEvery} * int($counter/$settings{ReportEvery})) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored user! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
                }
            }
            if ($watchlevel == 4) {
                $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored user! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (report $counter/#totalcounter; $settings{reportcounter})");
            }
        }
        $diff =~ s/\s//g;
        $settings{report} .= "# $theTime - [[$lang:user:$user]] ([[$lang:special:contributions/$user|contribs]]; $counter/$totalcounter) Monitored user $user - $fullurl ([[$lang:$page|$page]] - [$diff diff] - [[User:COIBot/UserReports/$user|COIBot UserReport]] - [[User:COIBot/LinkReports/$url|COIBot LinkReport]] - [[en:Wikipedia:WikiProject_Spam/LinkSearch/$url|Link report]] - [http://tools.wikimedia.de/~eagle/linksearch?search=$url Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$url Eagle's Spamsearch])\n";
        if ($lang eq 'en') {
            $settings{reporten} .= "# $theTime - [[user:$user]] ([[special:contributions/$user|contribs]]; $counter/$totalcounter) Monitored link $user - $fullurl ([[$page|$page]] - [$diff diff] - [[User:COIBot/UserReports/$user|COIBot UserReport]] - [[User:COIBot/LinkReports/$url|COIBot LinkReport]] - [[Wikipedia:WikiProject_Spam/LinkSearch/$url|Link report]] - [http://tools.wikimedia.de/~eagle/linksearch?search=$url Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$url Eagle's Spamsearch])\n";
            $settings{reportencounter}++
        }
        $settings{reports}++;
        $resulting = 1;
        $result = add_mysql('report',$user,$lang,$page,$url,$fullurl,$diff);
        if ($result == -1) {
            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "MySQL error while adding item to report.");
        }
    } else {
        $AtoB = weighing($search,$searchin);
        $BtoA = weighing($searchin,$search);
        $ratio = int(($AtoB * $BtoA)/10)/10;
        print("  Combined ratio = $ratio\n");
        if ($ratio > $settings{limit} ) {
            ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time);
            $year = 1900 + $yearOffset;
            if (length($hour) == 1) {
                $hour = "0$hour";
            }
            if (length($minute) == 1) {
                $minute = "0$minute";
            }
            if (length($second) == 1) {
                $second = "0$second";
            }
            if (length($dayOfMonth) == 1) {
                $dayOfMonth = "0$dayOfMonth";
            }
            $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
            $counter = 0;
            $totalcounter = 0;
            @reports = get_mysql('report','user',$user);
            if (@reports) {
                if (@reports[0]->{1} == -1) {
                    $counter--;
                    $totalcounter--;
                } else {
                    foreach $reports(@reports) {
                        if ($reports->{7} > (time() - $settings{LookBackTime})) {
                            $counter++;
                        }
                        $totalcounter++;
                    }
                }
            }
            $counter++;
            $totalcounter++;
            $settings{reportcounter}++;
            $watchlevel = 0;
            if ($watcher eq "LW") {
                $watchlevel = $settings{LWReportLevel};
                $kernel->post( $settings{reportserver} => privmsg => $channel => "ALERT! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] scores $AtoB% ($searchfrom->$searchto) & $BtoA% ($searchto->$searchfrom) (ratio: $ratio%) on $search <-> $searchin ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
            } 
            if ($watcher eq "RC") {
                $watchlevel = $settings{RCReportLevel};
                $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ALERT! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] scores $AtoB% ($searchfrom->$searchto) & $BtoA% ($searchto->$searchfrom) (ratio: $ratio%) on $search <-> $searchin ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
            }
            print("  Levels: $watcher ; $watchlevel ; LW - $settings{LWReportLevel} ($settings{ReportChannel1}) ; RC $settings{RCReportLevel} ($settings{ReportChannel2})\n");
            if ($lang eq 'en') {
                if ($watchlevel == 1) {
                    if ($counter == 1) {
                        $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Please check $diff (report $counter/$totalcounter; $settings{reportcounter})");
                    } elsif ($counter == $settings{ReportEvery} * int($counter/$settings{ReportEvery})) {
                        $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Please check $diff (report $counter/$totalcounter; $settings{reportcounter})");
                    }
                }
                if ($watchlevel == 2) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Please check $diff (report $counter/$totalcounter; $settings{reportcounter})");
                }
                if ($watchlevel == 3) {
                    if ($counter == 1) {
                        $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] scores $AtoB% ($searchfrom->$searchto) & $BtoA% ($searchto->$searchfrom) (ratio: $ratio%) on $search <-> $searchin ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
                    } elsif ($counter == $settings{ReportEvery} * int($counter/$settings{ReportEvery})) {
                        $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] (report $counter) scores $AtoB% ($searchfrom->$searchto) & $BtoA% ($searchto->$searchfrom) (ratio: $ratio%) on $search <-> $searchin ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
                    }
                }
                if ($watchlevel == 4) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] scores $AtoB% ($searchfrom->$searchto) & $BtoA% ($searchto->$searchfrom) (ratio: $ratio%) on $search <-> $searchin ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
                }
            }
            $result = add_mysql('report',$user,$lang,$page,$url,$fullurl,$diff);
            if ($result == -1) {
                $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "MySQL error while adding item to report.");
            }
            $diff =~ s/\s//g;
            $settings{report} .= "# $theTime - [[$lang:user:$user]] ([[$lang:special:contributions/$user|contribs]]; $counter/$totalcounter) scores $AtoB% ($searchfrom->$searchto) & $BtoA% ($searchto->$searchfrom) (ratio: $ratio%) on $search <-> $searchin ([[$lang:$page|$page]] - [$diff diff] - [[User:COIBot/UserReports/$user|COIBot UserReport]]";
            if (length($url) > 0 ) {
                $settings{report} .= " - [[User:COIBot/LinkReports/$url|COIBot LinkReport]] - [[en:Wikipedia:WikiProject_Spam/LinkSearch/$url|Link report]] - [http://tools.wikimedia.de/~eagle/linksearch?search=$url Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$url Eagle's Spamsearch]";
            }
            $settings{report} .= ")\n";
            if ($lang eq 'en') {
                $settings{reporten} .= "# $theTime - [[user:$user]] ([[special:contributions/$user|contribs]]; $counter/$totalcounter) scores $AtoB% ($searchfrom->$searchto) & $BtoA% ($searchto->$searchfrom) (ratio: $ratio%) on $search <-> $searchin ([[$page|$page]] - [$diff diff] - [[Wikipedia:WikiProject Spam/UserReports/$user|COIBot UserReport]]";
                if (length($url) > 0 ) {
                    $settings{reporten} .= " - [[Wikipedia:WikiProject Spam/LinkReports/$url|COIBot LinkReport]] - [[en:Wikipedia:WikiProject_Spam/LinkSearch/$url|Link report]] - [http://tools.wikimedia.de/~eagle/linksearch?search=$url Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$url Eagle's Spamsearch]";
                }
                $settings{reporten} .= ")\n";
                $settings{reportencounter}++
            }
            $resulting = 1;
            $settings{reports}++;
        } elsif (length($url) > 0) {
            $exists=check_mysql('monitor',lc($url));
            if ($exists == 1) {
                ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime(time);
                $year = 1900 + $yearOffset;
                if (length($hour) == 1) {
                    $hour = "0$hour";
                }
                if (length($minute) == 1) {
                    $minute = "0$minute";
                }
                if (length($second) == 1) {
                    $second = "0$second";
                }
                if (length($dayOfMonth) == 1) {
                    $dayOfMonth = "0$dayOfMonth";
                }
                $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
                $counter = 0;
                $totalcounter = 0;
                @reports = get_mysql('report','user',$user);
                if (@reports) {
                    if (@reports[0]->{1} == -1) {
                        $counter--;
                        $totalcounter--;
                    } else {
                        foreach $reports(@reports) {
                            if ($reports->{7} > (time() - $settings{LookBackTime})) {
                                $counter++;
                            }
                            $totalcounter++;
                        }
                    }
                }
                $counter++;
                $totalcounter++;
                $settings{reportcounter}++;
                $watchlevel = 0;
                if ($watcher eq "LW") {
                    $watchlevel = $settings{LWReportLevel};
                    $kernel->post( $settings{reportserver} => privmsg => $channel => "ALERT! Monitored link ($url)! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
                } 
                if ($watcher eq "RC") {
                    $watchlevel = $settings{RCReportLevel};
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel2} => "ALERT! Monitored link ($url)! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
                }
                print("  Levels: $watcher ; $watchlevel ; LW - $settings{LWReportLevel} ($settings{ReportChannel1}) ; RC $settings{RCReportLevel} ($settings{ReportChannel2})\n");
                if ($lang eq 'en') {
                    if ($watchlevel == 1) {
                        if ($counter == 1) {
                            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored link ($url)! Please check $diff (report $counter/$totalcounter; $settings{reportcounter})");
                        } elsif ($counter == $settings{ReportEvery} * int($counter/$settings{ReportEvery})) {
                            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored link ($url)! Please check $diff (report $counter/$totalcounter; $settings{reportcounter})");
                        }
                    }
                    if ($watchlevel == 2) {
                        $$kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored link ($url)! Please check $diff");
                    }
                    if ($watchlevel == 3) {
                        if ($counter == 1) {
                            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored link! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (first report/$totalcounter; $settings{reportcounter})");
                        } elsif ($counter == $settings{ReportEvery} * int($counter/$settings{ReportEvery})) {
                            $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored link! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (report $counter/$totalcounter; $settings{reportcounter})");
                        }
                    }
                    if ($watchlevel == 4) {
                        $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "ALERT! Monitored link! [[$lang:user:$user]]/[[$lang:special:contributions/$user]] added $fullurl ( $diff ) (report $counter/#totalcounter; $settings{reportcounter})");
                    }
                }
                $diff =~ s/\s//g;
                $settings{report} .= "# $theTime - [[$lang:user:$user]] ([[$lang:special:contributions/$user|contribs]]; $counter/$totalcounter) Monitored link - $fullurl ([[$lang:$page|$page]] - [$diff diff] - [[User:COIBot/UserReports/$user|COIBot UserReport]] - [[User:COIBot/LinkReports/$url|COIBot LinkReport]] - [[en:Wikipedia:WikiProject_Spam/LinkSearch/$url|Link report]] - [http://tools.wikimedia.de/~eagle/linksearch?search=$url Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$url Eagle's Spamsearch])\n";
                if ($lang eq 'en') {
                    $settings{reporten} .= "# $theTime - [[user:$user]] ([[special:contributions/$user|contribs]]; $counter/$totalcounter) Monitored link - $fullurl ([[$page|$page]] - [$diff diff] - [[Wikipedia:WikiProject Spam/UserReports/$user|COIBot UserReport]] - [[Wikipedia:WikiProject Spam/LinkReports/$url|COIBot LinkReport]] - [[Wikipedia:WikiProject_Spam/LinkSearch/$url|Link report]] - [http://tools.wikimedia.de/~eagle/linksearch?search=$url Eagle's Linksearch] - [http://tools.wikimedia.de/~eagle/spamsearch/$url Eagle's Spamsearch])\n";
                    $settings{reportencounter}++
                }
                $settings{reports}++;
                $resulting = 1;
                $result = add_mysql('report',$user,$lang,$page,$url,$fullurl,$diff);
                if ($result == -1) {
                    $kernel->post( $settings{reportserver} => privmsg => $settings{ReportChannel1} => "MySQL error while adding item to report.");
                }
            }
        }
    }
    undef $channel;
    undef $kernel;
    undef $sender;
    undef $lang;
    undef $user;
    undef $page;
    undef $url;
    undef $fullurl;
    undef $search;
    undef $searchin;
    undef $searchfrom;
    undef $searchto;
    undef $diff;
    undef $watcher;
    undef $watchlevel;
    undef $totalcounter;
    undef $counter;
    undef $reports;
    undef $year;
    undef $theTime;
    undef @reports;
    undef $AtoB;
    undef $BtoA;
    undef $ratio;
    undef $exists;
    undef $dayOfMonth;
    undef $month;
    undef $dayOfWeek;
    undef $second;
    undef $result;
    undef $minute;
    undef $hour;
    undef $yearOffset;
    undef $daylightSavings;
    undef $dayOfYear;
    undef;
    return $resulting;
}


sub weighing {
    my $searchstring = shift;
    my $instring = shift;
    $searchstring =~ s/[\.\s\_\<\>\[\]\*\(\)]//g;
    $instring =~ s/[\.\s\_\<\>\[\]\(\*\)]//g;
    my $searchlength = length($searchstring);
    my $totallength = length($instring);
    my $percentage = doweighing(lc($searchstring),lc($instring),$searchlength,$totallength,$searchlength,0);
    undef $searchstring;
    undef $instring;
    undef $searchlength;
    undef $totallength;
    undef;
    return int($percentage*10000)/100;    
}

sub doweighing {
    my $searchstring = shift;
    my $instring = shift;
    my $searchlength = shift;
    my $totallength = shift;
    my $totalsearchlength = shift;
    my $level = shift;
    my $inlength = length($instring);
    my $majorratio;
    my $percentage = 0;
    my $i;
    my $j;
    my @a;
    my $a;
    my @b;
    my $b;
    my $front;
    my $break;
    my $back;
    my $currentlength;
    my $hits;
    my $newbreak;
    my $newsearchtext;
    my $newstring;
    if ($searchlength > $inlength) {
        $searchlength = $inlength;
    }
    if ($totallength > 0 && $searchlength > 0 && length($searchstring) > 0) {
        $percentage = 0;
        $majorratio = $searchlength / $totalsearchlength;
        $i = 0;
        if (int($totallength/$searchlength)>1) {
            $i = 0;
            while ($i<$level) {
                $majorratio = $majorratio * $settings{deterioration};
                $i++;
            }
        }
        @a = ();
        @a = split(//,$searchstring);
        $front = $instring;
        $back = "";
        $break = "";
        $currentlength = length($front);
        $hits = 0;
        @b = ();
        $newbreak = "";
        $i = 0;
        while ($i<=(length($searchstring)-$searchlength)) {
            $break = "";
            for ($j=0;$j<$searchlength;$j++) {
                $break .= $a[$i+$j];
            }
            $break =~ s/([\[\.\]\\\*\+\?\{\}\(\)])/\\$1/g;
            $currentlength=length($front);
            ($front,$back) = split(/$break/,$front);
            $newstring = $front;
            $newstring .= $back;
            if (length($newstring) < $currentlength) {
                $i = $i + $searchlength;
                $percentage = $percentage + ($majorratio);
                $hits++;
                if (length($front) > 0) {
                    $newbreak = "";
                    foreach $b(@b) {
                        $newbreak .= $b;
                    }
                    if (length($newbreak)>0) {
                        $percentage = $percentage + doweighing($newbreak,$front,length($newbreak),$totallength,$totalsearchlength,$level);
                    }
                    @b = ();
                }
                $front = $back;
            } else {
                push(@b,$a[$i]);
                $i++;
            }
        }
        $newsearchtext = "";
        foreach $b(@b) {
            $newsearchtext .= $b;
        }
        while ($i<length($searchstring)) {
            $newsearchtext .= $a[$i];
            $i++;
        }
        if (int($totallength/$searchlength) > 1) {
            $level++;
        }
        unless (length($newsearchtext) == 0) {
            if (length($newsearchtext) >= $searchlength) {
                if ($searchlength > 1) {
                    $percentage = $percentage + doweighing($newsearchtext,$front,$searchlength-1,$totallength,$totalsearchlength,$level);
                }
            } else {
                $percentage = $percentage + doweighing($newsearchtext,$front,length($newsearchtext),$totallength, $totalsearchlength, $level);
            }
        }
    }
    undef $searchstring;
    undef $instring;
    undef $searchlength;
    undef $totallength;
    undef $totalsearchlength;
    undef $level;
    undef $inlength;
    undef $majorratio;
    undef $i;
    undef $j;
    undef @a;
    undef $a;
    undef @b;
    undef $b;
    undef $front;
    undef $break;
    undef $back;
    undef $currentlength;
    undef $hits;
    undef $newbreak;
    undef $newsearchtext;
    undef $newstring;
    undef;
    return $percentage;
}

sub inCIDRrange {
    my $tr1 = shift;
    my $tr2 = shift;
    my $tr3 = shift;
    my $tr4 = shift;
    my $cidr = shift;
    my $r1 = shift;
    my $r2 = shift;
    my $r3 = shift;
    my $r4 = shift;
    my $result = 0;
    my $s;
    my $t;
    my $mask;
    my $maskup;
    if ($cidr > 23) {
        if ($tr1 == $r1 && $tr2 == $r2 && $tr3 == $r3) {
            $t = $cidr - 24;
            $mask = 0;
            $maskup = 1;
            for ($s=1;$s<=$t;$s++) {
                $mask = $mask + $maskup;
                $maskup = 2 * $mask;
            }
            if (($r4 && $mask) == ($tr4 && $mask)) {
                $result = 1;
            }
        }
    } elsif ($cidr > 15) {
        if ($tr1 == $r1 && $tr2 == $r2) {
            $t = $cidr - 16;
            $mask = 0;
            $maskup = 1;
            for ($s=1;$s<=$t;$s++) {
                $mask = $mask + $maskup;
                $maskup = 2 * $mask;
            }
            if (($r3 && $mask) == ($tr3 && $mask)) {
                $result = 1;
            }
        }
    } elsif ($cidr > 7) {
        if ($tr1 == $r1 ) {
            $t = $cidr - 8;
            $mask = 0;
            $maskup = 1;
            for ($s=1;$s<=$t;$s++) {
                $mask = $mask + $maskup;
                $maskup = 2 * $mask;
            }
            if (($r2 && $mask) == ($tr2 && $mask)) {
                $result = 1;
            }
        }
    } else {
        $t = $cidr;
        $mask = 0;
        $maskup = 1;
        for ($s=1;$s<=$t;$s++) {
            $mask = $mask + $maskup;
            $maskup = 2 * $mask;
        }
        if (($r1 && $mask) == ($tr1 && $mask)) {
            $result = 1;
        }
    }
    return $result;
}

sub authenticate {
    my $cloak = shift;
    my $exists=check_mysql("trusted_users",$cloak);
    undef $cloak;
    undef;
    if ($exists==1) {
        undef $exists;
        return 1;
    } elsif ($exists == -1) {
        undef $exists;
        return -1;
    } elsif ($exists ==0) { 
        undef $exists;
        return 0; 
    }
}

sub add_mysql {
    my $mysql_handle;
    my $table=shift;
    my $value1=shift;
    my $value2=shift;
    my $value3=shift;
    my $value4=shift;
    my $value5=shift;
    my $value6=shift;
    my $value7=time();
    my $result=0;
    my $query="INSERT INTO $table VALUES ";
    eval {
        $mysql_handle=DBI->connect("dbi:mysql:coibot;localhost","coibot",$coidbpass);
    };
    if ($@) {
        $result = -1;
    }
    if ($result == 0) {
        print ("  Add: $table -> $value1 - $value2 - $value3 - $value4 - $value5 - $value6 - $value7\n");
        if ($table eq 'trusted_users') {
            eval {
                $value1=$mysql_handle->quote($value1);
            };
            if ($@) {
                $result = -1;
            }
            $query .= "($value1)"; #cloak
        }
        if ($table eq 'blacklist' | $table eq 'whitelist') {
            $value1 =~ s/ /_/g;
            $value2 =~ s/ /_/g;
            eval {
                $value1=$mysql_handle->quote($value1);
                $value2=$mysql_handle->quote($value2);
                $value3=$mysql_handle->quote($value3);
            };
            if ($@) {
                $result = -1;
            }
            $query .= "($value1,$value2,$value3)"; #username <-> string and reason
        }
        if ($table eq 'monitor') {
            eval {
                $value1=$mysql_handle->quote(lc($value1));
            };
            if ($@) {
                $result = -1;
            }
            $query .= "($value1)";
        }
        if ($table eq 'report') {
            $value1 =~ s/ /_/g;
            $value3 =~ s/ /_/g;
            eval {
                $value1=$mysql_handle->quote($value1);
                $value2=$mysql_handle->quote($value2);
                $value3=$mysql_handle->quote($value3);
                $value4=$mysql_handle->quote($value4);
                $value5=$mysql_handle->quote($value5);
                $value6=$mysql_handle->quote($value6);
                $value7=$mysql_handle->quote($value7);
            };
            if ($@) {
                $result =  -1;
            }
            $query .= "($value1,$value2,$value3,$value4,$value5,$value6,$value7)";  #username, language, page, url, fullurl, diff, time
        }
    }
    if ($result == 0) {
        my $query_handle=$mysql_handle->prepare($query);
        print "  Add: Executing query $query\n";
        $query_handle->execute;
        $query_handle->finish;
    }
    undef $mysql_handle;
    undef $table;
    undef $value1;
    undef $value2;
    undef $value3;
    undef $value4;
    undef $value5;
    undef $value6;
    undef $value7;
    undef $query;
    undef;
    return $result;
}

sub check_mysql {
    my $mysql_handle;
    my $table=shift;
    my $value1=shift;
    my $value2=shift;
    my $value3=shift;
    my $query="SELECT * FROM $table WHERE ";
    my $query_handle;
    my $result = 0;
    eval { $mysql_handle=DBI->connect("dbi:mysql:coibot;localhost","coibot",$coidbpass); };
    if ($@) {
        $result = -1;
    }
    if ($result == 0) {
        print("  check $table $value1 $value2\n");
        if ($table eq 'trusted_users') {
            eval {
                $value1=$mysql_handle->quote($value1);
            };
            if ($@) {
                $result = -1;
            }
            $query.="user_cloak=$value1";
        }
        if ($table eq 'monitor') {
            eval {
                $value1=$mysql_handle->quote(lc($value1));
            };
            if ($@) {
                $result = -1;
            }
            $query.="string=$value1";
        }
        if ($table eq 'blacklist' | $table eq 'whitelist') {
            $value1 =~ s/ /_/g;
            $value2 =~ s/ /_/g;
            eval {
                $value1=$mysql_handle->quote(lc($value1));
                $value2=$mysql_handle->quote(lc($value2));
            };
            if ($@) {
                $result = -1;
            }
            $query.="user=$value1 && string=$value2";
        }
        if ($table eq 'report') {
            if ($value1 eq 'user') {
                $value2 =~ s/\s/_/g;
                eval {
                    $value2=$mysql_handle->quote($value2);
                };
                if ($@) {
                    $result = -1;
                }
                $query.="WHERE user=$value2";
            } elsif ($value1 eq 'link') {
                $value2 =~ s/\s/_/g;
                eval {
                    $value2=$mysql_handle->quote($value2);
                };
                if ($@) {
                    $result = -1;
                }
                $query.="WHERE url=$value2";
            }
        }
    }
    if ($result == 0) {
        $query_handle=$mysql_handle->prepare($query);
        print "  Check: Executing query $query.\n";
        $query_handle->execute;
        if ($query_handle->rows > 0) {
            $result=1;
        }
    }
    undef $mysql_handle;
    undef $table;
    undef $value1;
    undef $value2;
    undef $value3;
    undef $query;
    undef $query_handle;
    undef;
    return $result;
}

sub get_mysql {
    my $table=shift;
    my $value1=shift;
    my $value2=shift;
    my $value3=shift;
    my $mysql_handle;
    my $name = "";
    my $link = "";
    my $language = "";
    my $page = "";
    my $url = "";
    my $fullurl = "";
    my $diff = "";
    my $query;
    my $time = "";
    my $query_handle;
    my $error = 0;
    my $reason;
    my @arr;
    eval {
        $mysql_handle=DBI->connect("dbi:mysql:coibot;localhost","coibot",$coidbpass);
    };
    if ($@) {
        unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
        print ("$@\n");
        $error = -1;
    }
    if ($error == 0) {
        $query="SELECT * FROM $table ";
        print("  get $table $value1 $value2\n");
        if ($table eq 'trusted_users') {
            eval {
                $value1=$mysql_handle->quote($value1);
            };
            if ($@) {
                print ("$@\n");
                unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
                $error = -1;
            }
            $query.="user_cloak=$value1";
        }
        if ($table eq 'monitor') {
            eval {
                $value1=$mysql_handle->quote(lc($value1));
                $value2=$mysql_handle->quote(lc($value2));
            };
            if ($@) {
                print ("$@\n");
                unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
                $error = -1;
            }
            $query.="string=$value1";
        }
        if ($table eq 'blacklist' | $table eq 'whitelist') {
            if ($value1 eq 'user') {
                $value2 =~ s/\s/_/g;
                eval {
                    $value2=$mysql_handle->quote(lc($value2));
                };
                if ($@) {
                    print ("$@\n");
                    unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
                    $error = -1;
                }
                $query.="WHERE user=$value2";
            } elsif ($value1 eq 'string') {
                $value2 =~ s/\s/_/g;
                eval {
                    $value2=$mysql_handle->quote(lc($value2));
                };
                if ($@) {
                    print ("$@\n");
                    unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
                    $error = -1;
                }
                $query.="WHERE string=$value2";
            } else {
                $value1 =~ s/\s/_/g;
                eval {
                    $value1=$mysql_handle->quote(lc($value1));
                };
                if ($@) {
                    print ("$@\n");
                    unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
                    $error = -1;
                }
                $value2 =~ s/\s/_/g;
                eval {
                    $value2=$mysql_handle->quote(lc($value2));
                };
                if ($@) {
                    print ("$@\n");
                    unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
                    $error = -1;
                }
                $query.="WHERE user=$value1 && string=$value2";
            }
        }
        if ($table eq 'report') {
            if ($value2 eq "*") {
            } else {
                if ($value1 eq 'user') {
                    $value2 =~ s/\s/_/g;
                    eval {
                        $value2=$mysql_handle->quote(lc($value2));
                    };
                    if ($@) {
                        print ("$@\n");
                        unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
                        $error = -1;
                    }
                    $query.="WHERE user=$value2";
                } elsif ($value1 eq 'link') {
                    $value2 =~ s/\s/_/g;
                    eval {
                        $value2=$mysql_handle->quote(lc($value2));
                    };
                    if ($@) {
                        print ("$@\n");
                        unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
                        $error = -1;
                    }
                    $query.="WHERE url=$value2";
                }
            }
        }
    }
    if ($error == 0) {
        print "  Get: Executing query $query.\n";
        eval {
            $query_handle=$mysql_handle->prepare($query);
        };
        if ($@) {
            print ("$@\n");
            unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
            $error = -1;
        }
    }
    if ($error == 0) {        
        eval {
            $query_handle->execute;
        };
        if ($@) {
            print ("$@\n");
            unshift(@arr,{1=>-1,2=>"-",3=>"-",4=>"-",5=>"-",6=>"-",7=>"-"});
            $error = -1;
        }
    }
    if ($error == 0) {        
        if ($table eq 'trusted_users') {
        }
        if ($table eq 'monitor') {
        }
        my $counter = 0;
        if ($table eq 'blacklist' | $table eq 'whitelist') { 
            $query_handle->bind_columns(\$name,\$link,\$reason);
            while ($query_handle->fetch) {
                $counter++;
                $link =~ s/_/ /g;
                $name =~ s/_/ /g;
                push(@arr,{1=>$name,2=>$link,3=>$reason});
                print("  $counter fetched: $name <-> $link - $reason.\n");
            }
        }
        if ($table eq 'report') { 
            $query_handle->bind_columns(\$name,\$language,\$page,\$url,\$fullurl,\$diff,\$time);  #username, language, page, url, fullurl, diff, time
            while ($query_handle->fetch) {
                $counter++;
                unshift(@arr,{1=>$name,2=>$language,3=>$page,4=>$url,5=>$fullurl,6=>$diff,7=>$time});
                print("  $counter fetched: $name - $language - $page - $url - $fullurl - $diff - $time.\n");
            }
        }
        eval { $query_handle->finish };
    }
    undef $mysql_handle;
    undef $table;
    undef $value1;
    undef $value2;
    undef $value3;
    undef $name;
    undef $link;
    undef $language;
    undef $page;
    undef $url;
    undef $fullurl;
    undef $diff;
    undef $time;
    undef $query;
    undef $reason;
    undef $error;
    undef;
    return @arr;
}

sub delete_mysql {
    my $table=shift;
    my $value1=shift;
    my $value2=shift;
    my $value3=shift;
    my $mysql_handle;
    my $returnvalue = 0;
    my $query_handle;
    my $query;
    eval {
        $mysql_handle=DBI->connect("dbi:mysql:coibot;localhost","coibot",$coidbpass);
    };
    if ($@) {
        $returnvalue = -1;
    } else {
        print("  delete $table $value1 $value2\n");
        $query="DELETE FROM $table WHERE ";
        if ($table eq 'trusted_users') {
            eval {
                $value1=$mysql_handle->quote($value1);
            };
            if ($@) {
                $returnvalue = -1;
            } else {
                $query.="user_cloak=$value1";
            }
        }
        if ($table eq 'monitor') {
            eval {
                $value1=$mysql_handle->quote(lc($value1));
            };
            if ($@) {
                $returnvalue = -1;
            } else {
                $query.="string=$value1";
            }
        }
        if ($table eq 'blacklist' | $table eq 'whitelist') {
            $value1 =~ s/\s/_/g;
            $value2 =~ s/\s/_/g;
            eval {
                $value1=$mysql_handle->quote(lc($value1));
                $value2=$mysql_handle->quote(lc($value2));
            };
            if ($@) {
                $returnvalue = -1;
            } else {
                $query.="user=$value1 && string=$value2";
            }
        }
        if ($returnvalue == 0) {
            $query_handle=$mysql_handle->prepare($query);
            print "  Delete: Executing query $query.\n";
            $query_handle->execute;
            $query_handle->finish;
        }
    }
    undef $mysql_handle;
    undef $query_handle;
    undef $table;
    undef $value1;
    undef $value2;
    undef $value3;
    undef $query;
    undef;
    return $returnvalue;
}