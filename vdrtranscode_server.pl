#!/usr/bin/perl
# vdrtranscode server Version 0.1
# 2011-04-25

# great thanks to this superb howto :
# http://trac.handbrake.fr/wiki/CLIGuide

use strict;
use warnings;
use Fcntl qw(:flock) ;
use Proc::Daemon;
use File::Find ;
use File::Copy ;
use File::Basename ;
use Getopt::Long ;
use Cwd;
use Logfile::Rotate;
use Math::BigInt ;

 
my $use = "vdrtranscode_server.pl

\$ vdrtranscode_server [--daemon][--log][--verbose][--help]

" ;

# main declarations
my $self="->" ;  # only for message system , no OO
my @VideoList ; # all [cut] directoys in /video
my $workfile ; # ${workdir}00001.ts     or           ${Outdir}vdrtranscode_tmp.ts ( if combined ts ) 
my $workdir ; # /video/24/[work-HDTV]08.24-15:00_-_16:00_Uhr/2010-06-08.03.36.5-0.rec/
my @TSList ; # combininig more than one ts file
my $daemon_flag ;
my $verbose_flag ;
my $log_flag ;
my $combined_ts ;
my $continue = 1; # condition of main loop

#Signals
$SIG{TERM} = \&quit ; # exit clean on Signal kill PID
$SIG{INT} = \&quit ; # exit clean on Signal Str+C
$SIG{CHLD} = 'IGNORE' ;

## GetOpt::Long 
GetOptions( 	"daemon" 	=>	\$daemon_flag ,
			"log" 	=>		\$log_flag ,
			"verbose" => 	\$verbose_flag,
			"help"	=> 	sub { print "$use" ; exit 0 ;}
) ;
my $config = &parse_config("/etc/vdrtranscode.conf") ;

my $Indir = "$config->{Indir}" ;
my $Outdir = "$config->{Outdir}" ;
# check given Directorys
foreach ( $Indir , $Outdir ) { 
  if ( -l $_ ) { $_ = readlink ( $_ ) } ; 
  unless ( -e $_ || -d $_ ) { &message("$_ not found or is not a Directory, check please...") ; &quit ;} 
  $_ .= "/" ;
  $_ =~s/\/\//\//g ;  
}

chdir($Outdir) ;

# change user to vdr running User  if called as root
if ( $> == 0 ) {
  my $uid = getpwnam($config->{vdr_user});
  $> = $uid ;
  &message("$self change effective User ID to $config->{vdr_user} : $uid") ;
}

if ( $daemon_flag ) {
  undef $verbose_flag ;
  Proc::Daemon::Init;
}
else { &message("$self running in foreground...") };

 
# leave our process ID for init
open MYPID , (">/tmp/vdrtranscode_server.pid") ;
print MYPID $$ ;
close MYPID ; 

# find binarys 
my $hb_bin = `which HandBrakeCLI` ; # eg. /usr/bin/HandBrakeCLI
chomp $hb_bin ;



while ($continue) { # main loop

# log rotation , to prevent large Logfiles
if ( -f "./vdrtranscode_server.log" and -s "./vdrtranscode_server.log" > 1024000 ) { # log file larger than 1024 Kbyte 
  message("$self rotate Logfiles...") ;
  my $gzip_bin =`which gzip`; chomp $gzip_bin ;
  my $logdatei = new Logfile::Rotate(
                    File  => "./vdrtranscode_server.log",
                    Count => 5,
                    Gzip  => "$gzip_bin",
                   );
  $logdatei->rotate();
  undef $logdatei;
}

# File find [cut- in /video
# reset on every new main loop
@VideoList =() ;
$workfile ="" ;
$workdir ="" ;

find ( \&funcfind_index , "$Indir" )  ; # alle /.*\/\[cut\].*\/.*rec\/00001.ts/  Dateien finden
# if yes
  if ( $#VideoList >= 0 ) {
     &message("$self found $VideoList[0]") ;
    #mark [work
    &rename_vdr_file( $VideoList[0] , "cut" , "work") ;
    ( $workdir = $VideoList[0] ) =~ s/\[cut/\[work/ ; # looks like /video/24/[work-HDTV]08.24-15:00_-_16:00_Uhr/2010-06-08.03.36.5-0.rec/

    # pre analysis to get fps for calculating start point
    undef $/ ; # unset line separator, to slurp the content to one var
    open INFO , "${workdir}/info" ; my $info_slurp = <INFO> ; close INFO ;
    $/ = "\n" ;
    my ( $fps ) = $info_slurp  =~/F\s(\d{2})\n/ ;
    $fps = 25 if ( $fps !~/50|25/ ) ; # set default if slurp of info failed 
# DEBUG
#$fps = 25 ;
    # test to prevent jerky playing on 25 fps sources
    my $set_fps="" ;
    if ( $fps == 25 ) { $set_fps ="-r $fps"} 
    &message("$self fps : $fps") ;

    # read all marks
    my @marks ;
    if ( -e "${workdir}/marks" ) { 
      open MARKS , "<${workdir}/marks" ; 
      @marks = <MARKS> ; 
      foreach (@marks) { $_ =~s/\s\w+.*$// } # cleanup entrys from noad comments
      close MARKS ;
    }

# call  subroutine combine_ts if
# - there are more than one ts files
# - there are more than 2 marks ( use as cutting engine )
 
if ( -e "${workdir}/00002.ts" or $#marks > 2 ) { #  need to be merged to one big ts file in ${$Outdir}
   &combine_ts("${Outdir}vdrtranscode_tmp.ts" , \@marks , $fps ) ;
  $combined_ts = 1 ; 
  ${workfile} = "${Outdir}vdrtranscode_tmp.ts" ;
}
else { ${workfile} = "${workdir}00001.ts" ; $combined_ts = 0 ;} 

    # analyse File
    &message("$self analyse...") ;
    my $workfile_dosh = dosh($workfile) ;


    # check marks and resolve start and end point
    # looks like : 
    # 0:05:36.25
    # 0:48:21.04
    my $param_start = "" ;
    my $param_stop = "" ;
    my $Durframes = 0 ;
   # use only if not combined ts before....
    if ( $combined_ts == 0 and $#marks > 0 ) {
	 if ( $#marks == 1 ) {
	    my $z = 0 ;
	    foreach ( @marks ) {
	      $z++ ;
	      my ( $Hour , $Minute , $Second , $Frame ) = $_ =~/(\d+):(\d+):(\d+).(\d+)/ ;
	      $param_start =  ( ($Hour * 60 *60 *$fps) + ($Minute * 60 *$fps) + ($Second *$fps)+ $Frame)  if $z == 1 ;
	      $param_stop =  ( ($Hour * 60 *60 *$fps) + ($Minute * 60 *$fps) + ($Second *$fps)+ $Frame) if $z == 2 ;
	    }
	  # stop frame is counted from start frame, not from Filebegin
	  $param_stop = $param_stop - $param_start ;
	  $Durframes = $param_stop ;
	  $param_stop = "--stop-at frame:$param_stop" ;
	  $param_start = "--start-at frame:$param_start" ;
	}
    }
    &message("$self \$param_start $param_start") ;
    &message("$self \$param_stop $param_stop") ;

    open ANALYZER , "nice -n $config->{nice_level} $hb_bin -i $workfile_dosh -o /dev/null $param_start -t 0  2>&1 |" ;

    # declarations 
    my $follow_audiotracks = 0 ;
    my $WxH = "" ;
    my ( $hours , $minutes , $seconds ) = "" ;
    my @Atracks = () ;
    my @new_crop = () ;
	while ( my $Zeile = <ANALYZER> ) {
	  # find  informations
	  # + duration: 00:55:41
	  if ( $Zeile =~/duration: / ) { 
	    ( $hours , $minutes , $seconds ) = $Zeile  =~/(\d+):(\d+):(\d+)/ ;
	  }
	  # + size: 1920x1080, pixel aspect: 1/1, display aspect: 1.78, 25.000 fps   
	  if ( $Zeile =~/size: / ) { 
	    ( $WxH , undef ) = $Zeile  =~/size:\s(\d+x\d+),.*,\s(\d+)\.\d+\sfps/ ;
	    &message("$self $WxH") ;
	    # calculate frames all over
	    if ( $Durframes == 0 ) { # no markers used 
		$Durframes = (( $hours * 60 * 60 )+ ( $minutes *60 ) + $seconds ) * $fps  ;
		&message("$self \$Durframes new $Durframes") ;
	    }
	  }
	  # get autocrop
	  #   + autocrop: 2/0/170/100
	  if ( $Zeile =~/autocrop: / ) {
	      my ( @orig_crop )  = $Zeile =~/autocrop:\s(\d+)\/(\d+)\/(\d+)\/(\d+)/ ;#top, Bottom , left , Right
	      # set both crops ( per top/ bottom and Left/Rigth) on larger crop found by handbrake, to prevent crop is only left and not right side for example
	      foreach ( 0..1 ) {$new_crop[$_] = $orig_crop[0] > $orig_crop[1] ? $orig_crop[0] : $orig_crop[1] ;} 
	      foreach ( 2..3 ) {$new_crop[$_] = $orig_crop[2] > $orig_crop[3] ? $orig_crop[2] : $orig_crop[3] ;}
	      # rounding by modulo 8( sprintf "%.0f" , ( $probe_memory_ammount_Mbyte / 25 )) * 25 ;
	      foreach ( @new_crop ) { $_ = ( sprintf "%.0f" , ( ${_} / 8 )) * 8 } ;	
	      &message("$self crop old : @orig_crop crop new : @new_crop") ;
	  }
	  # + audio tracks:
	  if ( $Zeile =~/audio tracks:/ ) { $follow_audiotracks = 1 ; }
	  if ( $Zeile =~/1,|2,|3,|4,/ and $follow_audiotracks == 1 ) { 
#	    print "$Zeile" ;
	    my ( $nr , $lang , $codec  ) = $Zeile  =~/\+\s(\d+),\s+(\w+)\s+\((\w+)\)/ ;
	      my $kbps = "" ;
	      if ( $Zeile =~ /AC3/ ) { ( $kbps )  = $Zeile  =~/,\s+(\d+)bps/ ; $kbps = $kbps / 1000 ; } # for Ac3 files get bitrate in kbps 
#	    print "$nr , $lang , $codec , $kbps\n" ;
	    @{$Atracks[$nr]}  = ( $lang , $codec , $kbps ) ; # structure Array[Tracknumber]->[field 0 : language] , [field 1 : codec] , [field 2: kbs]
	  # + 1, Deutsch (AC3) (2.0 ch) (iso639-2: deu), 48000Hz, 384000bps
	  # + 2, English (AC3) (2.0 ch) (iso639-2: eng), 48000Hz, 384000bps
	  }
	}
    close ANALYZER ;

# get Informations for processing from File Flag
# [mp4|m4v|mkv] [DD|noDD|HD-HD|HD-smallHD] [UVHQ|VHQ|HQ|MQ|LQ] [first|all]

  my ( $container , $dd_hd_sd , $quali , $atracks ) = $workdir =~ /\[work-(mp4|m4v|mkv)\|(DD|noDD|HD-HD|HD-smallHD)\|(UVHQ|VHQ|HQ|MQ|LQ|VLQ)\|(first|all)\]/ ;
  &message("$self $container , $dd_hd_sd , $quali , $atracks") ;

# build cmd line 
# audiopart
# -a 1,1,2 -A "Main Audio","Downmixed Audio","Director's Commentary"-E ac3,aac,aac -B auto,160,128 -R auto,auto,44100 -6 auto,dpl2,stereo 
# which audiotracks ?
my $param_a ="" ; # Orig. Audio Tracks to use
my $param_A ="" ; # Audio description
my $param_E ="" ; #  Audio Encoder
my $param_B ="" ; # Audio Bitrates
my $param_D ="" ;# normalize Audio 
my $nr_of_mp2 = 0 ;
my $nr_of_mp2_used = 0 ;
my @arr_of_track_contain_mp2 =() ;
my $nr_of_ac3 = 0 ;
my $nr_of_ac3_used = 0 ;
my $ac3_bitrate = 0 ;
my @arr_of_track_contain_ac3 =() ;
    foreach my $i ( 1..$#Atracks ) {
	#structure Array[Tracknumber]->[field 0 : language] , [field 1 : codec] , [field 2: kbs]
	if ( $Atracks[$i][1] =~/mp2/ ) { $nr_of_mp2++ ; push @arr_of_track_contain_mp2 , $i }
	if ( $Atracks[$i][1] =~/AC3/ ) { $nr_of_ac3++ ; push @arr_of_track_contain_ac3 , $i }
	&message("$self Atracks : $Atracks[$i][0], $Atracks[$i][1], $Atracks[$i][2]") ;
    }
# mp2
if ($atracks eq "first" and $nr_of_mp2 >=1 ) { 
      $param_a = "$arr_of_track_contain_mp2[0]," ; 
      $param_A = "\"$Atracks[$arr_of_track_contain_mp2[0]][0]\"" ;
      $param_E = "faac," ;
      $param_B = "$config->{AAC_Bitrate}," ;
      $param_D = "$config->{DRC}," ;
      $nr_of_mp2_used++ ;
}
if ($atracks eq "all" and $nr_of_mp2 >=1 ) {
      foreach  ( @arr_of_track_contain_mp2 ) {
	$param_a .= "${_}," ;
	$param_A .="\"$Atracks[${_}][0]\"," ;
	$param_E .= "faac," ;
	$param_B .= "$config->{AAC_Bitrate}," ;
	$param_D .= "$config->{DRC}," ;
	$nr_of_mp2_used++ ;
     }
}
# ac3
if ($dd_hd_sd =~ /^(DD|HD-HD|HD-smallHD)$/ and $nr_of_ac3 >=1) {
      foreach  ( @arr_of_track_contain_ac3 ) {
	$param_a .= "${_}," ;
	$param_A .="\"$Atracks[${_}][0]\"," ;
	$param_E .= "copy," ;
	$param_B .= "auto," ;
	$param_D .= "1.0," ;
	$nr_of_ac3_used++ ;
	$ac3_bitrate = "$Atracks[${_}][2]" ;
	
      }
}
foreach ( $param_a, $param_A , $param_E , $param_B , $param_D ) { $_ =~s/,$// ; } # remove last komma

my $param_crop = "--crop $new_crop[0]:$new_crop[1]:$new_crop[2]:$new_crop[3]" ;

&message("$self \$param_a -a $param_a\n\$param_A -A $param_A\n\$param_E -E $param_E\n\$param_B -B $param_B\n\$param_D -D $param_D\n\$param_crop $param_crop") ;



my $x264_opts ="ref=2:mixed-refs:bframes=2:b-pyramid=1:weightb=1:analyse=all:8x8dct=1:subme=7:me=umh:merange=24:trellis=1:no-fast-pskip=1:no-dct-decimate=1:direct=auto" ;

# Picture Size
# $dd_hd_sd holds one of this -> DD|noDD|HD-HD|HD-smallHD
my $param_X = 720 ; # max. Dimension Width ( 720 SD ( default )  , 1280 smallHD , 1920 HD )
$param_X = 1920 if ( $dd_hd_sd eq "HD-HD" ) ;
$param_X = 1280 if ( $dd_hd_sd eq "HD-smallHD" ) ;

# anamorphic encoding 
my $param_anamorph = "" ;
if ( $config->{anamorph_encoding} == 1 ) { $param_anamorph = "--loose-anamorphic" } # enable anamorph_encoding

# LQ for Webencoding -> sets maximum width of picture to 480 , disables anamorph encoding, sets AAC Rate to 96
if ( $quali eq "LQ" ) {  $param_X = 640 ;  $param_anamorph = "" ; }
if ( $quali eq "VLQ" ) {  $param_X = 480 ;  $param_anamorph = "" ; }
# TODO current all Audiotracks are passed from general Settings above , override here 
#  $ac3_bitrate = 96 ; ##TODO
#  ${container} = "m4v" if ( $nr_of_ac3 > 0 ) ; # change container from mp4 to m4v , if  ac3 avaible
#}

# TODO  wenn kein dd gewählt dann keine änderung in m4v  
  ${container} = "m4v" if ( $nr_of_ac3 > 0 and ${container} =~/mp4/ ) ; # change container from mp4 to m4v , if  ac3 avaible
  my $outfile = "${Outdir}vdrtrancode_tmp.${container}" ;
# recalculate Videobitrate to match round Mbyte Sizes ( cosmetic programming )
# $frames 
# $fps 
# $aac_nr 
# $aac_bitrate 
# $ac3_nr 
# $ac3_bitrate 
# $wish_bitrate 
my ( $recalc_video_bitrate , $target_Mbyte_size ) = &recalculate_video_bitrate( $Durframes , $fps , $nr_of_mp2_used , $config->{AAC_Bitrate}, $nr_of_ac3_used , $ac3_bitrate , $config->{$quali}) ;

# large file bug // mp4 file over 4 Gbyte Size need "--large-file"
my $set_large_file = "" ;
if ( $target_Mbyte_size >= 4000  and ${container} =~/(mp4|m4v)/ ) { $set_large_file = "--large-file" } ;

## strucure of proccesing line
## HandBrakeCLI -i /video/Wir_sind_Kaiser_-_Best_of/2010-10-26.21.55.15-0.rec/00001.ts  -o ./test3.mp4 -e x264 -O -b 500 -2 -T -x ref=2:mixed-refs:bframes=2:b-pyramid=1:
## weightb=1:analyse=all:8x8dct=1:subme=7:me=umh:merange=24:trellis=1:no-fast-pskip=1:no-dct-decimate=1:direct=auto -5 -B 128  --stop-at frame:3000 --strict-anamorphic
 
# use classic profile for speedup, lowers the encoding quallity 
my $encoder_profile_to_use ="-2 -T  -e x264 -x $x264_opts" ; # use x264 , instead ffmpeg , enable 2Pass and the x264 encoder options 
if ( $config->{use_classic_profile} eq 1 ) { $encoder_profile_to_use = "" ;  &message("$self use classic Profile , to speedup...") ; }

# overwrite for debug
#$param_stop = "--stop-at frame:3000" ;
 &message("$self JOBSTART --- $workfile") ;
 open HB , "nice -n $config->{nice_level} $hb_bin -i $workfile_dosh -O $set_large_file $param_crop $set_fps -b $recalc_video_bitrate $encoder_profile_to_use -5 -a $param_a -A $param_A -E $param_E -B $param_B -D $param_D $param_anamorph --modulus 8 -X $param_X -o $outfile $param_start $param_stop 2>&1 1>${Outdir}progress.log |" ;
## separate log for STOUT ( progress ) and STERR 
my $pid = fork();

      # childs code to handle STDOUT 
      if ($pid==0) {
	sleep 2 ; # wait $cmd is up
	if ( -f "${Outdir}progress.log" ) {
	$/="\r" ; # separator from \n to \r 
	  while (1) {
	    sleep 5 ; # 
	    exit 0 unless ( -f "${Outdir}progress.log" ) ; # exit on log lost by father
	    open (PROGRESS , "<${Outdir}progress.log" ) ;
	    my @lines = reverse <PROGRESS> ;
	    close PROGRESS ;
	    if ( $lines[0] ) {&message("$lines[0]") ; }
	  }
	}
      exit 0; # child exit
      }
      # end of child code


    while ( my $Zeile = <HB> ) {&message("° $Zeile") ;}
    unlink ("${Outdir}progress.log") ; # and ends childprocess
    close HB ;  

# cleanup merged ts file
    if ( $combined_ts == 1 and -e "${Outdir}vdrtranscode_tmp.ts" ) { unlink "${Outdir}vdrtranscode_tmp.ts" } ;
  # mark [del
#  ( $workfile = $workfile ) =~s/00001.ts// ;
   &rename_vdr_file( $workdir , "work" , "del") ;


#rename outfile
# $workfile looks like #  "/video/Der_Terminator/[work-m4v|HD-smallHD|VHQ|all]Science-Fiction/2010-06-08.03.36.5-0.rec/" 
my $copy_workdir = $workdir ;
$copy_workdir =~s/\/\d{4}-\d{2}-\d{2}.*rec\/// ;
$copy_workdir =~s/\[work.*(first|all)\]// ;
$copy_workdir =~s/$Indir// ;
$copy_workdir =~s/\//-/g ;

# include Videoformat on HD Targets
if ( $config->{Name_incl_Videoformat} == 1 and  $dd_hd_sd =~/(HD-smallHD|HD-HD)/ ) { 
  # orifg size is in $WxH
  my ( $orig_W , $orig_H ) = split "x" , $WxH ;
  my %target_dimension_preset = ( 1920 => '1080' , 1280 => '720' ) ;
  $copy_workdir .= "-${target_dimension_preset{${orig_W}}}p${fps}" ; #result in "Filename-1080p25"
}

$copy_workdir .= ".${container}" ;
rename ("$outfile" , "${Outdir}$copy_workdir") ;
&message("$self rename $outfile -> ${Outdir}$copy_workdir") ;

  }
# if no "[cut-" File found
 else {
  # wait 60 seconds
&message("waiting") ;
  sleep 60 ;
  }

# functions inside loop
#################################################################
sub dosh {
my $in = $_[0] ;
#$in =~ s/\s+/\ /g ; ## doppelte oder mehrere Leerzeichen auf eins reduzieren
$in =~ s/(\(\d+)\/(\d+\))/${1}\/${2}/g ;       ## das (1/5) problem
$in =~ s/([\s \( \) \$ \& \§ \" \! \? \[  \] \' \,\@ \| \> \<])/\\$1/g; # viele absonderliche Sonderzeichen für die shell qouten
$in =~ s/\\\\/\\/g ; # wenn ausdruck vorher schon geqotet war, die doppelten backslashes wieder auf einen kompenisieren
return $in ;
}
#################################################################
  sub funcfind_index {
  return unless ( $File::Find::name =~ /.*\/\[cut-.*\].*\/.*rec\/00001.ts$/ ) ;
  $File::Find::name=~s/00001.ts// ;
  push ( @VideoList , $File::Find::name ) ;
  }
#################################################################
 sub rename_vdr_file {
  # /video/24/[cut-HDTV]08.24-15:00_-_16:00_Uhr/2010-06-08.03.36.5-0.rec
  ( my $filename = $_[0] ) =~ s/\d{4}-\d{2}-.*\.rec// ;
  my $from = $_[1] ;
  my $to = $_[2] ;
  my $dir = dirname($filename) ; 
  my $file = basename($filename) ;
    ( my $file_neu = $file )=~ s/\[$from/\[$to/ ;
    &message("$self rename : ${dir}/${file} , ${dir}/${file_neu}") ;
  rename ( "${dir}/${file}" , "${dir}/${file_neu}" ) ;
  open REFRESH , ">$Indir/.update" ;
  close REFRESH ;
  }
#################################################################
 sub recalculate_video_bitrate {
  my $frames = shift ; 
  my $fps = shift ;
  my $aac_nr = shift ;
  my $aac_bitrate = shift ;
  my $ac3_nr = shift ;
  my $ac3_bitrate = shift ;
  my $wish_bitrate = shift ;

  # Calculate Size of AAC Files
  my $AudioKbyte ;
  if ( $aac_nr > 0 ) {
    $AudioKbyte = sprintf ( "%.8f" , ( $aac_bitrate * $frames / $fps / 8 ) ) ; # ohne Overhead
    if ( $aac_nr >= 1 ) { $AudioKbyte = $AudioKbyte *  $aac_nr }
  }
  else { $AudioKbyte = 0 }
#  print "\$AudioKbyte $AudioKbyte\n" ;
   
  # Calculate Size of Ac3 Files
  my	$ac3_kbyte_sec ;
  my $ac3_kbyteSize ;
  if ( $ac3_nr > 0 ) {
    $ac3_kbyte_sec = $ac3_bitrate / 8 ;
    $ac3_kbyteSize = sprintf ( "%.8f" , ( $ac3_kbyte_sec  * $frames  / $fps )) ;
    if ( $ac3_nr >= 1 ) { $ac3_kbyteSize = $ac3_kbyteSize * $ac3_nr }
  }
  else  { $ac3_kbyteSize = 0 }
#  print "\$ac3_kbyteSize $ac3_kbyteSize\n" ;


  # Memory count 
  my $minutes = $frames * $fps * 60 ;
  my $video_kbyte_sec = $wish_bitrate / 8 ; 
  my $video_kbyte_size = ( $video_kbyte_sec * $frames ) / $fps ; 
  my $probe_memory_ammount_kbyte = $video_kbyte_size + $ac3_kbyteSize + $AudioKbyte ;
  my $probe_memory_ammount_Mbyte = sprintf "%i" , $probe_memory_ammount_kbyte / 1024 ;
  &message("$self \$probe_memory_ammount_Mbyte $probe_memory_ammount_Mbyte") ;

  my $round_memory_ammount_Mbyte ;
  # rounding
  if ( $probe_memory_ammount_Mbyte < 20 ) {
	  $round_memory_ammount_Mbyte = ( sprintf "%.0f" , ( $probe_memory_ammount_Mbyte / 1 )) * 1  ;
#	  if ( $round_memory_ammount_Mbyte < $probe_memory_ammount_Mbyte ){ $round_memory_ammount_Mbyte+=5}
  }
  if ( $probe_memory_ammount_Mbyte < 100 ) {
	  $round_memory_ammount_Mbyte = ( sprintf "%.0f" , ( $probe_memory_ammount_Mbyte / 5 )) * 5  ;
#	  if ( $round_memory_ammount_Mbyte < $probe_memory_ammount_Mbyte ){ $round_memory_ammount_Mbyte+=5}
  }
  elsif ( $probe_memory_ammount_Mbyte < 600 ) {
	  $round_memory_ammount_Mbyte = ( sprintf "%.0f" , ( $probe_memory_ammount_Mbyte / 25 )) * 25 ;
#	  if ( $round_memory_ammount_Mbyte < $probe_memory_ammount_Mbyte ){ $round_memory_ammount_Mbyte+=25}
  }
  elsif ( $probe_memory_ammount_Mbyte >= 600 ) {
	  $round_memory_ammount_Mbyte = ( sprintf "%.0f" , ( $probe_memory_ammount_Mbyte / 50 )) * 50  ;
#	  if ( $round_memory_ammount_Mbyte < $probe_memory_ammount_Mbyte ){ $round_memory_ammount_Mbyte+=50}
  }
  &message("$self \$round_memory_ammount_Mbyte $round_memory_ammount_Mbyte") ;
  my $round_memory_ammount_kbyte = $round_memory_ammount_Mbyte * 1024 ;
  $round_memory_ammount_kbyte = $round_memory_ammount_kbyte * 1.018 ; # empiric factor add 
  my $round_memory_ammount_video_kbit = ( $round_memory_ammount_kbyte - $ac3_kbyteSize - $AudioKbyte ) * 8 ;
  my $round_memory_ammount_video_kbit_sec = sprintf "%.0f" , $round_memory_ammount_video_kbit / ( $frames / $fps ) ;
  &message("$self \$round_memory_ammount_video_kbit_sec $round_memory_ammount_video_kbit_sec") ;
  return $round_memory_ammount_video_kbit_sec , $round_memory_ammount_Mbyte ; 
}
#################################################################
sub combine_ts {
  my $target_ts = shift ;
  my $ref_marks = shift ;
  my $fps = shift ;
  @TSList = () ;
  ## get Byte Positions based on marks
  &message("$self combine TS Files active") ;
  &message("$self get Byte Positions based on marks") ;

  my @reads ;
  open (INDEX, "<$workdir/index") or die ("Couldn't open $workdir/index");

  my $y = 0 ; # initial Number of reading Areas per ts-File
  my $zaehlfilenumber = 0 ; # current ts-File Counter
  foreach (@$ref_marks){
  # can hold 0:05:33.16 Logo start cleanup
    my $buffer;
    my @bytepos=(0, 0, 0, 0);
    my ($h,$m,$s,$f) = split /[:.]/,$_;
    ($f,undef)=split / /, $f;
    chomp $f ;
    my $frame = ($h * 3600 + $m * 60 + $s)* $fps + $f-1;
#    &message("$self HMSF : $h,$m,$s,$f -> frame $frame") ;

# from recording.c vdr 1.7.18
#  uint64_t offset:40; // up to 1TB per file (not using off_t here - must definitely be exactly 64 bit!) 8byte
#  int reserved:7;     // reserved for future use 1 byte
#  int independent:1;  // marks frames that can be displayed by themselves (for trick modes) 1 byte
#  uint16_t number:16; // up to 64K files per recording 2 byte
#  tIndexTs(off_t Offset, bool Independent, uint16_t Number)
#  {
#    offset = Offset;
#    reserved = 0;
#    independent = Independent;
#    number = Number;
#  }
#  };
      seek (INDEX, 8*$frame,'0');
      read(INDEX, $buffer, 8);
      my ( @hex_littleendian ) = unpack ("H2H2H2H2H2H2H2H2" , $buffer) ; # 5 bytes offset , 1 byte reserved , 2 bytes filename
#    print "\@hex_littleendian @hex_littleendian\n" ;
      my @hex_ordert = reverse @hex_littleendian ;  # now 2 bytes filename , 1 byte reserved , 5 bytes offset 
      my $hex_offset = join "" , @hex_ordert[3..7] ;
      my $hex_number = join "" , @hex_ordert[0..1] ;
      # for use in 32 Bit 
      my $offset = Math::BigInt->new("0x$hex_offset");
#      my $offset = hex ("$hex_offset") ;
      my $filenumber = hex ("$hex_number") ;

#      &message("$self offset : $hex_offset -> $offset number : $hex_number -> $filenumber") ;

    # if current marker is locatet in a new TS_File
      if ( $zaehlfilenumber != $filenumber ) { $y = 0 ; $zaehlfilenumber = $filenumber }
      $y++ ;
      &message("$self filenumber -> $filenumber ||  HMSF : ${h}:${m}:${s}.${f} || Frame -> $frame || Byteposition -> $offset") ;
      $reads[$filenumber][$y]=$offset ; # $reads[nr of vdr file][curr Nr of Cutting Marks per File]=Byteposition
   };
    close (INDEX);
  ## Liste aller Video TS Files im Dir machen
  find ( \&funcfind_ts , "$workdir" )  ;

  &message("$self Creating cut-list...") ;
# Adding Start and Stop Marks if reading Areas are set over Fileborders :
#	 _________--------------______----------------______________________
#	off 			on 		   off    	on         		off
# |---------------------------------------||-----------------------------------------|
#     001.vdr              					002.vdr
#   	/		  /		      /		  /   //		   /
# 							      ^New Marker on FileBorders
  my $inout = 0 ;
  foreach my $w ( 1..$#reads ) { # Array of all VdrFiles --> within anonym Array of Marks , Starts on field 1, not 0 --> within Byteposition
	my $ww = sprintf("%0.5i",$w) ; # aus Zählung 1, 2 , 3 wieder 00001 , 00002 ,00003 herstellen
	( my $curr_vdr  = $TSList[$w - 1] )=~  s/\d+\.ts/${ww}\.ts/ ; # foreach -> zu bearbeitenden File mit voller Pfadangabe und 00x benennen
	my $curr_size = -s $curr_vdr ; # Filesize
	next if ($w == 1 &&  $#{$reads[$w]} < 1) ; # wenn 001.vdr keine Marks hat, Sprung  zum nächsten File  (  002.vdr )
	if ( $w == 1 && $#{$reads[$w]}%2 != 0) { # wenn 001.vdr ungerade marks hat, ....
		$reads[$w][$#{$reads[$w]} + 1]= $curr_size ; # .... dann fullsize als letzten marker ....
		$inout = 1 ; # und Flag setzen, dass 001.vdr  nicht mit Stop Marker marker endete
		&message ("$self 00001 no Stop, insert one") ;
	}
	if ( $w != 1 && $#{$reads[$w]} >= 1 && $inout == 1 ) { # wenn ungleich 001.vdr und "mehr als / oder" eine  Marks und vorhergehender File endet nicht mit Stoppmarke
		if ( $#{$reads[$w]}%2 != 0) { 	# Wenn ungerade Anzahl von Marks, File endet also mit Stop Marker
			unshift @{$reads[$w]},0 ; # Leeren neuen Marker vorne dran bauen , wenn letzter File keinen Stopmarker hatte
			$reads[$w][1]=0; # ersten Marker mit Bytepos Null belegen, die nachfolgenden haben sich ja durch unshift 1 nach hinten bewegt
			$inout = 0 ; # Endete mit Stopmarker
			&message ("$self 0000${w} no Start --> insert one\n") ;
		}
		else { # Marker Anzahl gerade
			unshift @{$reads[$w]},0 ; # Leeren neuen Marker vorne dran bauen , da letzter File keinen Stopmarker hatte
			$reads[$w][1]=0; # ersten Marker mit Bytepos Null belegen, die nachfolgenden haben sich ja durch unshift 1 nach hinten bewegt
			$reads[$w][$#{$reads[$w]} + 1]= $curr_size ; # weil ja gerade Anzahl von Markern, endet auch dieser File nicht mit Stop Marker --> letzter bytepos ende bei fullsize ;
			$inout = 1 ; # Endete nicht mit Stopmarker
			&message ("$self 0000${w} no Start no End  --> insert both\n") ;
		}
	}
	elsif ( $w != 1 && $#{$reads[$w]} >= 1 && $inout == 0 ) { # wenn ungleich 001.vdr und eine/mehrere marks , Start Marker stimmt bereits
		if ( $#{$reads[$w]}%2 != 0) { 	# Wenn ugerade Anzahl von Marks, File endet also auch nicht mit Stop Marker
			$reads[$w][$#{$reads[$w]} + 1]= $curr_size ; # ende Marker bei fullsize setzen ;
			$inout = 1 ;
			&message ("$self 0000${w} no Stop --> insert one\n") ;
		}
	}
	if ( $w != 1 && $#{$reads[$w]} == -1 && $inout == 1 ) { # wenn ungleich 001.vdr und keine marks
		$reads[$w][1]=0 ; # start bei null
		$reads[$w][$#{$reads[$w]} + 1]= $curr_size ; # ende bei fullsize ;
			&message ("$self 0000${w} no Markers, but marked \"on-reading\" during last File , no Start no End  --> insert both\n") ;
	}

		foreach my $j ( 1..$#{$reads[$w]} ) {
			&message ("$self $w $j $reads[$w][$j]") ;
		}
  }
#einzel ts zu geschnittenem ts
    open TOFH, ">$target_ts" or die "cannot open $target_ts for writing..." ;
    &message ("$self Combining ts-file using cut-list...") ;
    my $byteshift = 16777216 ;
    foreach my $w ( 1..$#reads ) {
	next if ( $#{$reads[$w]} <=1 ) ; # überspringen wenn weniger als 2 Marks
	my $lesevorgaenge = $#{$reads[$w]} / 2 ;
	my $lvshift = -1 ;
	foreach my $j ( 1..$lesevorgaenge ) {
		$lvshift = $lvshift +2 ; # start at anonym Array[1] not [0]
		&message ("$self file $w") ;
		my $start = $reads[$w][$lvshift] ;# anonym Array[1] / Array[3] / Array[5]
		my $stop = $reads[$w][$lvshift + 1] ; # anonym Array[2] / Array[4] / Array[6]
		my $vdr = sprintf ("%0.3i" , $w) ;
		my @curr = grep /${vdr}\.ts/, @TSList ;
		my $act = $curr[0] ;

		open FH , "<$act" or die " konnte $act nicht öffnen..." ;
		my $cont ;
		while (1) {
			my $aktpos = tell FH ;
			# debug
			if ( $aktpos >= $stop ) { &message ("$self endpos : $aktpos")} ;

			last if ( $aktpos >= $stop ) ;
			if ( $stop - $aktpos < $byteshift ) { $byteshift = $stop - $aktpos };
			if ( $aktpos == 0 ) {
				#debug
				&message ("$self seeking : $start") ;

				seek FH,  $start, 0 ;
				$aktpos = tell FH ;
			}
			read FH, $cont , $byteshift ;
			print TOFH $cont ;
		}
		undef $cont ;
		close FH ;
	}
  }
  close TOFH ;
## end read write
}
#################################################################


#################################################################
# end while} 
}
#################################################################
sub funcfind_ts {
return unless ( $File::Find::name =~ /\d+\.ts/ ) ;
push ( @TSList , $File::Find::name ) ;
}
#################################################################

# global functions
#################################################################
sub quit {
  message("*quit...") ;
  unlink ("/tmp/vdrtranscode_server.pid") if ( -f "/tmp/vdrtranscode_server.pid" ) ;
  die  ; 
}
#################################################################
# thanks to http://www.patshaping.de/hilfen_ta/codeschnipsel/perl-configparser.htm
sub parse_config($)
{
 my $file = shift;
 local *CF;

 open(CF,'<'.$file) or die "Open $file: $!";
 read(CF, my $data, -s $file);
 close(CF);

 my @lines  = split(/\015\012|\012|\015/,$data);
 my $config = {};
 my $count  = 0;

 foreach my $line(@lines)
 {
  $count++;

  next if($line =~ /^\s*#/);
  next if($line !~ /^\s*\S+\s*=.*$/);

  my ($key,$value) = split(/=/,$line,2);

  # Remove whitespaces at the beginning and at the end

  $key   =~ s/^\s+//g;
  $key   =~ s/\s+$//g;
  $value =~ s/^\s+//g;
  $value =~ s/\s+$//g;

#  die "Configuration option '$key' defined twice in line $count of configuration file '$file'" if($config->{$key});

  $config->{$key} = $value;
 }

 return $config;
}
#################################################################
sub message {
  # consider if message goes to STDOUT , Logfile or /dev/zero
   my $message = shift ;
   chomp $message ;
  if ( $verbose_flag and not $daemon_flag ) {
    print "$message\n" ;
  }
  if ( $log_flag ) {
    open LOG , ">>./vdrtranscode_server.log" ;
    flock(LOG, LOCK_EX) ;
    unless ( $message =~/waiting/ ) { print LOG "$message\n" ; } # dont flood log with "waiting"
    close LOG ;
   }
}
