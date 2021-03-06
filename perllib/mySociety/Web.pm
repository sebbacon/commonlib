#!/usr/bin/perl
#
# mySociety/Web.pm:
# CGI-like class which we can extend.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: team@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Web.pm,v 1.24 2009-02-16 16:34:14 matthew Exp $
#

package mySociety::Web;

use strict;

use Encode;
use HTML::Entities;

use Carp;
use CGI qw(-nosticky);
my $have_cgi_fast = 0;
eval {
    use mySociety::CGIFast;
    $have_cgi_fast = 1;
};

use HTTP::Date qw();

use fields qw(q scratch site unicode);
@mySociety::Web::ISA = qw(Exporter); # for the Import* methods

BEGIN {
    use Exporter ();
    our @ISA = qw(Exporter);
    our @EXPORT_OK = qw(ent NewURL);
}
our @EXPORT_OK;

sub ent ($) {
    my $s = shift;
    return encode_entities($s, '<>&"');
}

=item new [QUERY]

Construct a new mySociety::Web object, optionally from an existing QUERY. Uses
mySociety::CGIFast if available, or CGI otherwise.

=cut
sub new ($;%) {
    my mySociety::Web $self = shift;
    my %params = @_;
    my $q = $params{q};
    if (!defined($q)) {
        $q = $have_cgi_fast ? new mySociety::CGIFast() : new CGI();
        return undef if (!defined($q)); # reproduce mySociety::CGIFast behaviour
    }
    $q->autoEscape(1);
    $self = fields::new($self) unless ref $self;
    $self->{q} = $q;
    $self->{scratch} = { };
    $self->{unicode} = $params{unicode};
    return $self;
}

# q
# Access to the underlying CGI (or whatever) object.
sub q ($) {
    return $_[0]->{q};
}

=item scratch

Return a reference to the internal scratchpad.

=cut
sub scratch ($) {
    return $_[0]->{scratch};
}

# AUTOLOAD
# Is-a inheritance isn't safe for this kind of thing, so we use has-a.
sub AUTOLOAD {
    my $f = $mySociety::Web::AUTOLOAD;
    $f =~ s/^.*:://;
    local $@ = undef;
    eval "sub $f { my \$q = shift; return \$q->{q}->$f(\@_); }";
    goto(&$mySociety::Web::AUTOLOAD);
}

=item param

Calls underlying CGI param, and perhaps decode_utf8 the return value.

=cut
sub param {
    my mySociety::Web $self = shift;
    if (wantarray) {
        return $self->{q}->param(@_);
    } elsif ($self->{unicode}) {
        return decode_utf8($self->{q}->param(@_));
    } else {
        return $self->{q}->param(@_);
    }
}

=item ParamValidate PARAMETER CHECK [DEFAULT]

Return the value of the named PARAMETER, assuming it passes CHECK, or DEFAULT
(or if none is given, undef) otherwise. CHECK is either a code ref which is
passed the mySociety::Web object and the value of the parameter and should
return 1 if it is valid; or a regexp.

=cut
sub ParamValidate ($$$;$) {
    my mySociety::Web $self = shift;
    my ($name, $check, $default) = @_;
    my $val = $self->param($name);
    return $default if (!defined($val));
    if (ref($check) eq 'CODE') {
        return $default unless (&$check($self, $val));
    } elsif (ref($check) eq 'Regexp') {
        return $default unless ($val =~ $check);
    } else {
        croak "CHECK must be a code ref or a regexp";
    }
    return $val;
}

=item Import WHAT PARAMS

Import parameters (WHAT = 'p') or cookies (WHAT = 'c') from the query into the
caller's own namespace; each specified parameter (cookie) NAME is assigned to a
variable "$qp_NAME" ("$qc_NAME"), which should be declared with our(...).
PARAMS gives a hash of NAME => DEFAULT or NAME => [CHECK, DEFAULT]. If a
parameter is not specified, it takes the given DEFAULT value. Optionally, a
CHECK may be given to validate each parameter; a parameter which does not
validate is assigned its DEFAULT value. CHECK may be either a regexp
(qr/.../...) or a code reference, which will be passed the mySociety::Web
object and the named parameter; it should return true if the parameter is valid
and false otherwise.

This function may be called several times for one request.

I<This function is quite slow, so don't use it in a time-critical page.>

=cut
sub Import ($$%) {
    my ($self, $what, %p) = @_;
    my $q = $self->q();

    croak("WHAT should be 'p' for parameters, or 'c' for cookies")
        unless ($what =~ m#^[pc]$#);
    my $p = ($what eq 'p');

    while (my ($name, $x) = each(%p)) {
        my $val = $p ? $self->param($name) : $q->cookie($name);
        if (ref($x) eq 'ARRAY') {
            croak("PARAMS->{$name} should be a 2-element list") unless (@$x == 2);
            my ($check, $dfl) = @$x;
            if (!defined($val)) {
                $val = $dfl;
            } elsif (ref($check) eq 'CODE') {
                $val = $dfl if (!&$check($self, $val));
            } elsif (ref($check) eq 'Regexp') {
                $val = $dfl if ($val !~ $check);
            } else {
                croak("PARAMS->{$name}->[0] should be a code reference or regexp");
            }
        } elsif (defined(ref($x))) {
            croak("PARAMS->{$name} is a reference to " . ref($x) . "; should be scalar or array");
        } else {
            $val = $x if (!defined($val));
        }

        {
            no strict 'refs';
            ${"q${what}_$name"} = $val;
            push(@mySociety::Web::EXPORT, "\$q${what}_$name");
        }
    }

    {
        # Black magic.
        local $Exporter::ExportLevel = 1;
        import mySociety::Web;
    }
}

=item ImportMulti PARAMS

Import multi-valued parameters from the query into the caller's own namespace;
each specified parameter NAME is assigned to an array "@qp_NAME", which should
be declared with our(...). PARAMS gives a hash of NAME => CHECK; each CHECK is
applied to each instance of a multi-valued parameter, filtering the values
supplied by the client.

I<This function is quite slow, so don't use it in a time-critical page.>

=cut
sub ImportMulti ($%) {
    my ($self, %p) = @_;
    my $q = $self->q();

    while (my ($name, $check) = each(%p)) {
        my @val;
        if (ref($check) eq 'CODE') {
            @val = grep { &$check($self, $_) } $self->param('name');
        } elsif (ref($check) eq 'Regexp') {
            @val = grep($check, $self->param('name'));
        } else {
            croak("PARAMS->{$_} should be a code reference or regexp");
        }

        {
            no strict 'refs';
            @{"qp_$name"} = @val;
            push(@mySociety::Web::EXPORT, "\@qp_$name");
        }
    }

    {
        # Black magic.
        local $Exporter::ExportLevel = 1;
        import mySociety::Web;
    }
}

=item NewURL Q [PARAM VALUE ...]

Return a URL with changed parameters. Each PARAM gives the name of a parameter;
the VALUE may be a scalar, a reference list to indicate that a multivalued
parameter should be added; or undef to indicate that the parameter should be
removed in the new URL. The special PARAMs of -url and -retain state an
override URL and whether to keep the current parameters respectively.

=cut
sub NewURL ($%) {
    my ($q, %p) = @_;
    # $q->url(-relative=>1) is buggy in CGI.pm v3.15 as packaged with etch.
    # But $q->request_uri() doesn't exist until v3.11 and we have v3.04 on sarge.
    my $url = $p{-url} || $ENV{REQUEST_URI} || '';
    $url =~ s/\?.*$//s; # Strip query string
    ($url) = $url =~ m{([^/]+)$} unless $p{-url};
    $url ||= '';
    my %params;
    %params = map { $_ => $q->param($_) || '' } $q->param()
        if $p{-retain};
    foreach my $key (keys %p) {
        next if $key eq '-url' || $key eq '-retain';
        if (defined $p{$key}) {
            $params{$key} = $p{$key};
        } else {
            delete $params{$key};
        }
    }
    if (keys %params) {
        my @v = ();
        foreach my $key (keys %params) {
            next unless defined $params{$key};
            my $v = $params{$key};
            croak("can't use ref to " . ref($v) . " as param value")
                if (ref($v) && ref($v) ne 'ARRAY');
            $v = [$v] if (!ref($v));
            push(@v, map { urlencode($key) . '=' . urlencode($_) } @$v);
        }
        $url .= '?' . join(';', @v);
    }
    return $url;
}

=item header PARAMS

Return an HTTP header, influenced by PARAMS as in CGI.pm.

=cut
sub header ($%) {
    my ($self, %p) = @_;
    if (!exists($p{"-type"})) {
        $p{"-type"} = 'text/html; charset=utf-8';
    }
    return $self->q()->header(%p);
}

=item urlencode STRING

Return a URL-encoded copy of STRING.

=cut
sub urlencode ($) {
    my $v = $_[0];
    utf8::encode($v);
    $v =~ s/([^A-Za-z0-9])/sprintf('%%%02x', ord($1))/ge;
    return $v;
}

sub start_form ($%) {
    my ($self, %p) = @_;
    $p{'-accept_charset'} = 'utf-8' if (!exists($p{'-accept_charset'}));
    return $self->q()->start_form(%p);
}

# quote_etag ETAG
# Return a properly-quoted version of ETAG.
sub quote_etag ($) {
    my $etag = shift;
    $etag =~ s/([\\"])/\\$1/g;
    return qq("$etag");
}

=item Cond304 [TIME] [ETAG]

Send a 304 Not Modified response with the given TIME and ETAG (assumed weak).

=cut
sub Cond304 ($$;$) {
    my mySociety::Web $self = shift;
    my ($time, $etag) = @_;

    croak "Must set at least one of TIME and ETAG"
        unless (defined($time) || defined($etag));

    print $self->q()->header(
        -charset => 'utf-8',
                -status => '304 Not Modified',
                (defined($time) ? (-Last_Modified => HTTP::Date::time2str($time)) : ()),
                (defined($etag) ? (-Etag => 'W/' . quote_etag($etag)) : ())
            );
}

=item Maybe304 [TIME] [ETAG]

If the current request is GET or HEAD and has an If-Modified-Since: or
If-None-Match: header, and if the given last-modified TIME or ETAG (assumed
weak) match that header, then emit a 304 Not Modified response and return
true; otherwise return false.

=cut
sub Maybe304 ($$;$) {
    my mySociety::Web $self = shift;
    my ($time, $etag) = @_;

    croak "Must set at least one of TIME and ETAG"
        unless (defined($time) || defined($etag));

    my $q = $self->q();
    return 0 if ($q->request_method() !~ /^(GET|HEAD)$/);

    my $ims;
    if (defined($time)
        && ($ims = $q->http('If-Modified-Since'))
        && defined($ims = HTTP::Date::str2time($ims))
        && $ims >= int($time)) {        # XXX in case it came from DB or Time::HiRes
        $self->Cond304($time, $etag);
        return 1;
    } elsif (defined($etag) && (my $etags = $q->http('If-None-Match'))) {
        my $q = 'W/' . quote_etag($etag);
        foreach (split(/\s*,\s*/, $etags)) {
            if ($_ eq $q) {
                $self->Cond304($time, $etag);
                return 1;
            }
        }
    } else {
        return 0;
    }
}

1;
