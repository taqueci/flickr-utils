=head1 NAME

flickr-album-export.pl - download a photoset

=head1 SYNOPSIS

    flickr-album-export.pl [OPTION] ... PHOTOSET_ID ...

=head1 DESCRIPTION

This script downloads files specified by PHOTOSET_ID.

The files are saved into "album/PHOTOSET_TITLE" as default.

The API key, secret and authentication token are specified by options,
environment variables or a configuration file.

~/.flickrrc is used as a default configuration file.
The format is the same as flickr_upload's one.

=head1 OPTIONS

=over 4

=item --key=KEY

Use KEY as an API key.

=item --secret=SECRET

Use SECRET as a secret.

=item --token=TOKEN

Use TOKEN as an auth token.

=item --rc=FILE

Read FILE as rc file.

=item -o DIR, --output=DIR

Save files into DIR.

=item -l FILE, --log=FILE

Write log to FILE.

=item --verbose

Print verbosely.

=item --help

Print this help.

=back

=head1 AUTHOR

Takeshi Nakamura <taqueci.n@gmail.com>

=head1 COPYRIGHT

Copyright (C) 2014 Takeshi Nakamura. All Rights Reserved.

=cut

use strict;
use warnings;

use File::Path;
use Flickr::API;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev gnu_compat);
use LWP::UserAgent;
use Pod::Usage;

use PLib;

# Override URLs.
my $uri = 'https://api.flickr.com/services/upload/';
my $rest_uri = 'https://api.flickr.com/services/rest/';
my $auth_uri = 'https://api.flickr.com/services/auth/';

my $rc = "$ENV{HOME}/.flickrrc";

my %opt = (output => 'album');
GetOptions(\%opt, 'key=s', 'secret=s', 'token=s', 'rc=s',
		   'output|o=s',
		   'log|l=s', 'verbose', 'help') || exit 1;

p_set_log($opt{log}) if defined($opt{log});
p_set_verbose(1) if $opt{verbose};

pod2usage(-exitval => 0, -verbose => 2, -noperldoc => 1) if $opt{help};

(@ARGV > 0) || p_error_exit(1, "Too few arguments");

my @photoset_id = @ARGV;

my $config = read_config($opt{rc} // $ENV{FLICKR_RC} // $rc);

my $key = $opt{key} // $ENV{FLICKR_KEY} // $config->{key};
my $secret = $opt{secret} // $ENV{FLICKR_SECRET} // $config->{secret};
my $token = $opt{token} // $ENV{FLICKR_TOKEN} // $config->{auth_token};

check_values('key' => $key, 'secret' => $secret, 'token' => $token) || exit 1;

my $api = Flickr::API->new({key => $key, secret => $secret,
							rest_uri => $rest_uri, auth_uri => $auth_uri});

p_verbose("Downloading albums");
download_albums($api, $token, $opt{output}, \@photoset_id) || exit 1;

p_verbose("Completed!\n");

exit 0;


sub read_config {
	my $file = shift;
	my $fh;
	my %config;

	return {} unless -f $file;

	unless (open($fh, $file)) {
		p_error("$file: $!");
		return undef;
	}

	while (my $line = <$fh>) {
		chomp $line;

		# Remove comment.
		$line =~ s/#.*$//;

		my ($key, $val) = ($line =~ /^\s*(\w+)=(.+)\s*$/);

		$config{$key} = $val if defined($key) && defined($val);
	}

	close($fh);

	return \%config;
}

sub check_values {
	my %value = @_;
	my $nerr = 0; # Number of errors.

	while (my ($key, $val) = each %value) {
		unless (defined($val)) {
			p_error("Undefined value for $key");
			$nerr++;
		}
	}

	return $nerr == 0;
}

sub download_albums {
	my ($api, $token, $dir, $photoset_id) = @_;
	my $nerr = 0; # Number of errors.

	my $ua = LWP::UserAgent->new();

	foreach my $p (@$photoset_id) {
		p_verbose("Downloading album \#$p");
		my $title = album_title($api, $token, $p);
		my $photo = photos_info($api, $token, $p);

		unless (defined($title) && defined($photo)) {
			$nerr++;
			next;
		}

		my $pdir = "$dir/" . name($title);

		unless (-d $pdir || mkpath $pdir) {
			p_error("$pdir: $!");
			$nerr++;
			next;
		}

		foreach my $q (@$photo) {
			my $id = $q->{id};
			my $name = name($q->{title});

			p_verbose("Downloading photo \#$id");
			download_file($ua, $q->{url}, $pdir, $name) || $nerr++;
		}
	}

	return $nerr == 0;
}

sub album_title {
	my ($api, $token, $id) = @_;

	my %arg = (auth_token => $token, photoset_id => $id);

	my $res = $api->execute_method('flickr.photosets.getInfo', \%arg);

	unless ($res->{success}) {
		p_error("\#$id: Failed to get album information");
		return undef;
	}

	foreach my $x (@{$res->{tree}->{children}->[1]->{children}}) {
		next unless $x->{type} eq 'element';

		return $x->{children}->[0]->{content} if $x->{name} eq 'title';
	}

	p_error("\#$id: No title is found");

	return undef;
}

sub photos_info {
	my ($api, $token, $id) = @_;
	my @photo;
	my $nerr = 0;

	my %arg = (auth_token => $token, photoset_id => $id,
			   extras => 'media,url_o');

	my $res = $api->execute_method('flickr.photosets.getPhotos', \%arg);

	unless ($res->{success}) {
		p_error("\#$id: Failed to get album information");
		return undef;
	}

	foreach my $x (@{$res->{tree}->{children}->[1]->{children}}) {
		next unless defined($x->{name}) && ($x->{name} eq 'photo');

		my $attr = $x->{attributes};

		my $id = $attr->{id};
		my $url = ($attr->{media} eq 'video') ?
			video_url($api, $token, $id) : $attr->{url_o};

		defined($url) || $nerr++;

		push(@photo, {title => $attr->{title}, id => $id, url => $url});
	}

	return ($nerr == 0) ? \@photo : undef;
}

sub video_url {
	my ($api, $token, $id) = @_;

	my %arg = (auth_token => $token, photo_id => $id);

	my $res = $api->execute_method('flickr.photos.getSizes', \%arg);

	unless ($res->{success}) {
		p_error("\#$id: Failed to get photo information");
		return undef;
	}

	foreach my $x (@{$res->{tree}->{children}->[1]->{children}}) {
		next unless $x->{type} eq 'element';

		my $attr = $x->{attributes};

		return $attr->{source} if $attr->{label} eq 'Video Original';
	}

	p_error("\#$id: No URL is found");

	return undef;
}

sub download_file {
	my ($ua, $url, $dir, $name) = @_;
	my $fh;

	my $r = $ua->get($url);

	unless ($r->is_success()) {
		p_error("$name: Failed to download");
		return 0;
	}

	my $file = "$dir/$name" . ext($r->header('Content-Type'));

	unless (open($fh, '>', $file)) {
		p_error("$file: $!");
		return 0;
	}

	p_verbose("Saving file as $file");
	binmode($fh);
	print $fh $r->content();

	close($fh);

	return 1;
}

sub ext {
	my $mime = shift;

	my %mime2ext = (
		'image/jpeg'      => '.jpeg',
		'image/gif'       => '.gif',
		'image/png'       => '.png',
		'image/tiff'      => '.tiff',
		'video/x-msvideo' => '.avi',
		'video/x-ms-wmv'  => '.wmv',
		'video/quicktime' => '.mov',
		'video/mpeg'      => '.mpeg',
		'video/mp4'       => '.mp4',
		'video/3gpp'      => '.3gp'
	);

	my $e = $mime2ext{$mime};

	unless (defined($e)) {
		p_warning("$mime: Unknown MIME type");
		$e = "";
	}

	return $e;
}

sub name {
	my $name = shift;

	# Replace characters which is not allowed in file name.
	$name =~ s/[\/\\\?\*\:\|\"\<\>\ ]/_/g;

	return $name;
}
