=head1 NAME

PLib - My private library

=head1 SYNOPSIS

    use PLib;

    p_set_message_prefix("Foo");
    p_set_log("/var/log/plib.log");
    p_set_verbose(1);

    p_message("Hello world");
    p_warning("We will rock you");
    p_error("Welcome to the jungle");
    p_verbose("We are the champions");
    p_log("Wanna whole lotta love");

=cut

package PLib;

use strict;
use warnings;

use Carp;

use base 'Exporter';

our @EXPORT = qw(p_message p_warning p_error p_verbose p_log p_set_message_prefix p_set_log p_set_verbose p_exit p_error_exit);

our $p_message_prefix = "";
our $p_log_file;
our $p_is_verbose = 0;

sub p_message {
	my @msg = ($p_message_prefix, @_);

	print STDERR @msg, "\n";
	p_log(@msg);
}

sub p_warning {
	my @msg = ("*** WARNING ***: ", $p_message_prefix, @_);

	print STDERR @msg, "\n";
	p_log(@msg);
}

sub p_error {
	my @msg = ("*** ERROR ***: ", $p_message_prefix, @_);

	print STDERR @msg, "\n";
	p_log(@msg);
}

sub p_verbose {
	my @msg = @_;

	$p_is_verbose && print STDERR @msg, "\n";
	p_log(@msg);
}

sub p_log {
	my @msg = @_;
	my $fh;

	return unless defined($p_log_file);

	open($fh, '>>', $p_log_file) || die "$p_log_file: $!\n";
	print $fh @msg, "\n";
	close($fh);
}

sub p_set_message_prefix {
	my $prefix = shift;

	defined($prefix) || croak "Invalid argument";

	$p_message_prefix = $prefix;
}

sub p_set_log {
	my $file = shift;

	defined($file) || croak "Invalid argument";

	$p_log_file = $file;
}

sub p_set_verbose {
	$p_is_verbose = (!defined($_[0]) || ($_[0] != 0));
}

sub p_exit {
	my ($val, @msg) = @_;

	print STDERR @msg, "\n";
	p_log(@msg);
	exit $val;
}

sub p_error_exit {
	my ($val, @msg) = @_;

	p_error(@msg);
	exit $val;
}

1;
