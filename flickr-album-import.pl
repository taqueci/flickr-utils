=head1 NAME

flickr-album-import.pl - upload photos and create a new photoset

=head1 SYNOPSIS

    flickr-album-import.pl [OPTION] ... TITLE PATH ...

=head1 DESCRIPTION

This script uploads files specified by PATH, and creates a new album entitled
TITLE.
If PATH is a directory, it uplaods files under PATH recursively.

The first file found in PATH is used as primary photo of the album.

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

=item -d DESC, --description=DESC

Use DESC as a description of both photoset and photos.

=item -t TAG, --tag=TAG

Use TAG as a tag of photos. This option can be specified multiple times.

=item -s, --sort

Upload files in an ascending order of file path.

=item -k, --keep-going

Don't exit program even if error occurs in uploading.

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

use File::Find;
use Flickr::Upload;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev gnu_compat);
use Pod::Usage;

use PLib;

my $FILE_SIZE_MAX = 300 * 1024 * 1024;

# Override URLs.
my $uri = 'https://api.flickr.com/services/upload/';
my $rest_uri = 'https://api.flickr.com/services/rest/';
my $auth_uri = 'https://api.flickr.com/services/auth/';

my $rc = "$ENV{HOME}/.flickrrc";

my %opt;
GetOptions(\%opt, 'key=s', 'secret=s', 'token=s', 'rc=s',
		   'description|d=s', 'tag|t=s@', 'sort|s', 'keep-going|k',
		   'log|l=s', 'verbose', 'help') || exit 1;

p_set_log($opt{log}) if defined($opt{log});
p_set_verbose(1) if $opt{verbose};

pod2usage(-exitval => 0, -verbose => 2, -noperldoc => 1) if $opt{help};

(@ARGV > 1) || p_error_exit(1, "Too few arguments");

my ($title, @path) = @ARGV;

my $config = read_config($opt{rc} // $ENV{FLICKR_RC} // $rc);

my $key = $opt{key} // $ENV{FLICKR_KEY} // $config->{key};
my $secret = $opt{secret} // $ENV{FLICKR_SECRET} // $config->{secret};
my $token = $opt{token} // $ENV{FLICKR_TOKEN} // $config->{auth_token};

check_values('key' => $key, 'secret' => $secret, 'token' => $token) || exit 1;

my $api = Flickr::Upload->new({key => $key, secret => $secret,
							   rest_uri => $rest_uri, auth_uri => $auth_uri});

my $desc = $opt{description};

p_verbose("Finding target files");
my $file = find_files(@path) || exit 1;

@$file = sort @$file if $opt{sort};

p_verbose("Uploading photos");
my $photo_id = upload_photos($api, $token, $uri, $file, $opt{tag}, $desc,
							 $opt{'keep-going'}) || exit 1;

my $primary = shift @$photo_id;

p_verbose("Creating album '$title' with \#$primary");
my $album_id = create_album($api, $token, $title, $primary, $desc) || exit 1;

p_verbose("Adding photos");
add_photos($api, $token, $album_id, $photo_id) || exit 1;

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

sub find_files {
	my @path = @_;
	my @file;
	my $nerr = 0; # Number of errors.

	foreach my $p (@path) {
		if (-e $p) {
			find(sub {push(@file, $File::Find::name) if -f $_ &&
	$_ =~ /\.(jpeg|jpg|gif|png|tiff|avi|wmv|mov|mpg|mpeg|mp4|3gp)$/i}, $p);
		}
		else {
			p_error("$p: $!");
			$nerr++;
		}
	}

	return ($nerr == 0) ? \@file : undef;
}

sub upload_photos {
	my ($api, $token, $uri, $file, $tag, $desc, $keep_going) = @_;
	my $nerr = 0;

	my %arg = (auth_token => $token, uri => $uri, async => 0);

	$arg{tags} = join(" ", @$tag) if defined($tag);
	$arg{description} = $desc if defined($desc);

	my @photo_id;

	foreach my $f (@$file) {
		p_verbose("Uploading $f");
		my $id = upload_file($api, $f, \%arg);

		unless (defined($id)) {
			$keep_going || $nerr++;
			next;
		}

		p_verbose("$f is uploaded as \#$id");
		push(@photo_id, $id);
	}

	return (($nerr == 0) && (@photo_id > 0)) ? \@photo_id : undef;
}

sub upload_file {
	my ($api, $file, $arg) = @_;

	# Check file size.
	unless (-s $file <= $FILE_SIZE_MAX) {
		p_error("$file: Size too large");
		return undef;
	}

	my $id = $api->upload(photo => $file, %$arg);

	# Retry.
	unless (defined($id)) {
		p_verbose("Try again");
		$id = $api->upload(photo => $file, %$arg);
	}

	unless (defined($id)) {
		p_error("$file: Failed to upload");
		return undef;
	}

	return $id;
}

sub create_album {
	my ($api, $token, $title, $photo_id, $desc) = @_;

	my %arg = (auth_token => $token,
			   title => $title, primary_photo_id => $photo_id);

	$arg{description} = $desc if defined($desc);

	my $resp = $api->execute_method('flickr.photosets.create', \%arg);

	unless ($resp->{success}) {
		p_error("$title: Failed to create album");
		return undef;
	}

	return $resp->{tree}->{children}->[1]->{attributes}->{id};
}

sub add_photos {
	my ($api, $token, $photoset_id, $photo_id) = @_;
	my $nerr = 0;

	foreach my $p (@$photo_id) {
		p_verbose("Adding photo \#$p");

		# Note %arg is modified by execute_method().
		my %arg = (auth_token => $token, photoset_id => $photoset_id,
				   photo_id => $p);

		my $resp = $api->execute_method('flickr.photosets.addPhoto', \%arg);

		unless ($resp->{success}) {
			p_error("\#$p: Failed to add photo");
			$nerr++;
		}
	}

	return $nerr == 0;
}
