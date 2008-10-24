# -*- Mode: cperl; coding: utf-8; cperl-indent-level: 4 -*-
# vim: ts=4 sts=4 sw=4:
use strict;
package CPAN;
$CPAN::VERSION = '1.93_51';
$CPAN::VERSION =~ s/_//;

# we need to run chdir all over and we would get at wrong libraries
# there
use File::Spec ();
BEGIN {
    if (File::Spec->can("rel2abs")) {
        for my $inc (@INC) {
            $inc = File::Spec->rel2abs($inc) unless ref $inc;
        }
    }
}
use CPAN::Author;
use CPAN::HandleConfig;
use CPAN::Version;
use CPAN::CacheMgr;
use CPAN::Complete;
use CPAN::Debug;
use CPAN::FTP;
use CPAN::Index;
use CPAN::InfoObj;
use CPAN::Queue;
use CPAN::Tarzip;
use CPAN::DeferredCode;
use CPAN::Shell;
use CPAN::LWP::UserAgent;
use Carp ();
use Config ();
use Cwd qw(chdir);
use DirHandle ();
use Exporter ();
use ExtUtils::MakeMaker qw(prompt); # for some unknown reason,
                                    # 5.005_04 does not work without
                                    # this
use File::Basename ();
use File::Copy ();
use File::Find;
use File::Path ();
use FileHandle ();
use Fcntl qw(:flock);
use Safe ();
use Sys::Hostname qw(hostname);
use Text::ParseWords ();
use Text::Wrap ();

# protect against "called too early"
sub find_perl ();
sub anycwd ();

no lib ".";

require Mac::BuildTools if $^O eq 'MacOS';
if ($ENV{PERL5_CPAN_IS_RUNNING} && $$ != $ENV{PERL5_CPAN_IS_RUNNING}) {
    $ENV{PERL5_CPAN_IS_RUNNING_IN_RECURSION} ||= $ENV{PERL5_CPAN_IS_RUNNING};
    my $rec = $ENV{PERL5_CPAN_IS_RUNNING_IN_RECURSION} .= ",$$";
    my @rec = split /,/, $rec;
    # warn "# Note: Recursive call of CPAN.pm detected\n";
    my $w = sprintf "# Note: CPAN.pm is running in process %d now", pop @rec;
    my %sleep = (
                 5 => 30,
                 6 => 60,
                 7 => 120,
                );
    my $sleep = @rec > 7 ? 300 : ($sleep{scalar @rec}||0);
    my $verbose = @rec >= 4;
    while (@rec) {
        $w .= sprintf " which has been called by process %d", pop @rec;
    }
    if ($sleep) {
        $w .= ".\n\n# Sleeping $sleep seconds to protect other processes\n";
    }
    if ($verbose) {
        warn $w;
    }
    local $| = 1;
    while ($sleep > 0) {
        printf "\r#%5d", --$sleep;
        sleep 1;
    }
    print "\n";
}
$ENV{PERL5_CPAN_IS_RUNNING}=$$;
$ENV{PERL5_CPANPLUS_IS_RUNNING}=$$; # https://rt.cpan.org/Ticket/Display.html?id=23735

END { $CPAN::End++; &cleanup; }

$CPAN::Signal ||= 0;
$CPAN::Frontend ||= "CPAN::Shell";
unless (@CPAN::Defaultsites) {
    @CPAN::Defaultsites = map {
        CPAN::URL->new(TEXT => $_, FROM => "DEF")
    }
        "http://www.perl.org/CPAN/",
        "ftp://ftp.perl.org/pub/CPAN/";
}
# $CPAN::iCwd (i for initial)
$CPAN::iCwd ||= CPAN::anycwd();
$CPAN::Perl ||= CPAN::find_perl();
$CPAN::Defaultdocs ||= "http://search.cpan.org/perldoc?";
$CPAN::Defaultrecent ||= "http://search.cpan.org/uploads.rdf";
$CPAN::Defaultrecent ||= "http://cpan.uwinnipeg.ca/htdocs/cpan.xml";

# our globals are getting a mess
use vars qw(
            $AUTOLOAD
            $Be_Silent
            $CONFIG_DIRTY
            $Defaultdocs
            $Echo_readline
            $Frontend
            $GOTOSHELL
            $HAS_USABLE
            $Have_warned
            $MAX_RECURSION
            $META
            $RUN_DEGRADED
            $Signal
            $SQLite
            $Suppress_readline
            $VERSION
            $autoload_recursion
            $term
            @Defaultsites
            @EXPORT
           );

$MAX_RECURSION = 32;

@CPAN::ISA = qw(CPAN::Debug Exporter);

# note that these functions live in CPAN::Shell and get executed via
# AUTOLOAD when called directly
@EXPORT = qw(
             autobundle
             bundle
             clean
             cvs_import
             expand
             force
             fforce
             get
             install
             install_tested
             is_tested
             make
             mkmyconfig
             notest
             perldoc
             readme
             recent
             recompile
             report
             shell
             smoke
             test
             upgrade
            );

sub soft_chdir_with_alternatives ($);

{
    $autoload_recursion ||= 0;

    #-> sub CPAN::AUTOLOAD ;
    sub AUTOLOAD {
        $autoload_recursion++;
        my($l) = $AUTOLOAD;
        $l =~ s/.*:://;
        if ($CPAN::Signal) {
            warn "Refusing to autoload '$l' while signal pending";
            $autoload_recursion--;
            return;
        }
        if ($autoload_recursion > 1) {
            my $fullcommand = join " ", map { "'$_'" } $l, @_;
            warn "Refusing to autoload $fullcommand in recursion\n";
            $autoload_recursion--;
            return;
        }
        my(%export);
        @export{@EXPORT} = '';
        CPAN::HandleConfig->load unless $CPAN::Config_loaded++;
        if (exists $export{$l}) {
            CPAN::Shell->$l(@_);
        } else {
            die(qq{Unknown CPAN command "$AUTOLOAD". }.
                qq{Type ? for help.\n});
        }
        $autoload_recursion--;
    }
}

{
    my $x = *SAVEOUT; # avoid warning
    open($x,">&STDOUT") or die "dup failed";
    my $redir = 0;
    sub _redirect(@) {
        #die if $redir;
        local $_;
        push(@_,undef);
        while(defined($_=shift)) {
            if (s/^\s*>//){
                my ($m) = s/^>// ? ">" : "";
                s/\s+//;
                $_=shift unless length;
                die "no dest" unless defined;
                open(STDOUT,">$m$_") or die "open:$_:$!\n";
                $redir=1;
            } elsif ( s/^\s*\|\s*// ) {
                my $pipe="| $_";
                while(defined($_[0])){
                    $pipe .= ' ' . shift;
                }
                open(STDOUT,$pipe) or die "open:$pipe:$!\n";
                $redir=1;
            } else {
                push(@_,$_);
            }
        }
        return @_;
    }
    sub _unredirect {
        return unless $redir;
        $redir = 0;
        ## redirect: unredirect and propagate errors.  explicit close to wait for pipe.
        close(STDOUT);
        open(STDOUT,">&SAVEOUT");
        die "$@" if "$@";
        ## redirect: done
    }
}

#-> sub CPAN::shell ;
sub shell {
    my($self) = @_;
    $Suppress_readline = ! -t STDIN unless defined $Suppress_readline;
    CPAN::HandleConfig->load unless $CPAN::Config_loaded++;

    my $oprompt = shift || CPAN::Prompt->new;
    my $prompt = $oprompt;
    my $commandline = shift || "";
    $CPAN::CurrentCommandId ||= 1;

    local($^W) = 1;
    unless ($Suppress_readline) {
        require Term::ReadLine;
        if (! $term
            or
            $term->ReadLine eq "Term::ReadLine::Stub"
           ) {
            $term = Term::ReadLine->new('CPAN Monitor');
        }
        if ($term->ReadLine eq "Term::ReadLine::Gnu") {
            my $attribs = $term->Attribs;
            $attribs->{attempted_completion_function} = sub {
                &CPAN::Complete::gnu_cpl;
            }
        } else {
            $readline::rl_completion_function =
                $readline::rl_completion_function = 'CPAN::Complete::cpl';
        }
        if (my $histfile = $CPAN::Config->{'histfile'}) {{
            unless ($term->can("AddHistory")) {
                $CPAN::Frontend->mywarn("Terminal does not support AddHistory.\n");
                last;
            }
            $META->readhist($term,$histfile);
        }}
        for ($CPAN::Config->{term_ornaments}) { # alias
            local $Term::ReadLine::termcap_nowarn = 1;
            $term->ornaments($_) if defined;
        }
        # $term->OUT is autoflushed anyway
        my $odef = select STDERR;
        $| = 1;
        select STDOUT;
        $| = 1;
        select $odef;
    }

    $META->checklock();
    my @cwd = grep { defined $_ and length $_ }
        CPAN::anycwd(),
              File::Spec->can("tmpdir") ? File::Spec->tmpdir() : (),
                    File::Spec->rootdir();
    my $try_detect_readline;
    $try_detect_readline = $term->ReadLine eq "Term::ReadLine::Stub" if $term;
    unless ($CPAN::Config->{inhibit_startup_message}) {
        my $rl_avail = $Suppress_readline ? "suppressed" :
            ($term->ReadLine ne "Term::ReadLine::Stub") ? "enabled" :
                "available (maybe install Bundle::CPAN or Bundle::CPANxxl?)";
        $CPAN::Frontend->myprint(
                                 sprintf qq{
cpan shell -- CPAN exploration and modules installation (v%s)
ReadLine support %s

},
                                 $CPAN::VERSION,
                                 $rl_avail
                                )
    }
    my($continuation) = "";
    my $last_term_ornaments;
  SHELLCOMMAND: while () {
        if ($Suppress_readline) {
            if ($Echo_readline) {
                $|=1;
            }
            print $prompt;
            last SHELLCOMMAND unless defined ($_ = <> );
            if ($Echo_readline) {
                # backdoor: I could not find a way to record sessions
                print $_;
            }
            chomp;
        } else {
            last SHELLCOMMAND unless
                defined ($_ = $term->readline($prompt, $commandline));
        }
        $_ = "$continuation$_" if $continuation;
        s/^\s+//;
        next SHELLCOMMAND if /^$/;
        s/^\s*\?\s*/help /;
        if (/^(?:q(?:uit)?|bye|exit)$/i) {
            last SHELLCOMMAND;
        } elsif (s/\\$//s) {
            chomp;
            $continuation = $_;
            $prompt = "    > ";
        } elsif (/^\!/) {
            s/^\!//;
            my($eval) = $_;
            package CPAN::Eval;
            use strict;
            use vars qw($import_done);
            CPAN->import(':DEFAULT') unless $import_done++;
            CPAN->debug("eval[$eval]") if $CPAN::DEBUG;
            eval($eval);
            warn $@ if $@;
            $continuation = "";
            $prompt = $oprompt;
        } elsif (/./) {
            my(@line);
            eval { @line = Text::ParseWords::shellwords($_) };
            warn($@), next SHELLCOMMAND if $@;
            warn("Text::Parsewords could not parse the line [$_]"),
                next SHELLCOMMAND unless @line;
            $CPAN::META->debug("line[".join("|",@line)."]") if $CPAN::DEBUG;
            my $command = shift @line;
            eval {
                local (*STDOUT)=*STDOUT;
                @line = _redirect(@line);
                CPAN::Shell->$command(@line)
              };
            _unredirect;
            if ($@) {
                my $err = "$@";
                if ($err =~ /\S/) {
                    require Carp;
                    require Dumpvalue;
                    my $dv = Dumpvalue->new(tick => '"');
                    Carp::cluck(sprintf "Catching error: %s", $dv->stringify($err));
                }
            }
            if ($command =~ /^(
                             # classic commands
                             make
                             |test
                             |install
                             |clean

                             # pragmas for classic commands
                             |ff?orce
                             |notest

                             # compounds
                             |report
                             |smoke
                             |upgrade
                            )$/x) {
                # only commands that tell us something about failed distros
                CPAN::Shell->failed($CPAN::CurrentCommandId,1);
            }
            soft_chdir_with_alternatives(\@cwd);
            $CPAN::Frontend->myprint("\n");
            $continuation = "";
            $CPAN::CurrentCommandId++;
            $prompt = $oprompt;
        }
    } continue {
        $commandline = ""; # I do want to be able to pass a default to
                           # shell, but on the second command I see no
                           # use in that
        $Signal=0;
        CPAN::Queue->nullify_queue;
        if ($try_detect_readline) {
            if ($CPAN::META->has_inst("Term::ReadLine::Gnu")
                ||
                $CPAN::META->has_inst("Term::ReadLine::Perl")
            ) {
                delete $INC{"Term/ReadLine.pm"};
                my $redef = 0;
                local($SIG{__WARN__}) = CPAN::Shell::paintdots_onreload(\$redef);
                require Term::ReadLine;
                $CPAN::Frontend->myprint("\n$redef subroutines in ".
                                         "Term::ReadLine redefined\n");
                $GOTOSHELL = 1;
            }
        }
        if ($term and $term->can("ornaments")) {
            for ($CPAN::Config->{term_ornaments}) { # alias
                if (defined $_) {
                    if (not defined $last_term_ornaments
                        or $_ != $last_term_ornaments
                    ) {
                        local $Term::ReadLine::termcap_nowarn = 1;
                        $term->ornaments($_);
                        $last_term_ornaments = $_;
                    }
                } else {
                    undef $last_term_ornaments;
                }
            }
        }
        for my $class (qw(Module Distribution)) {
            # again unsafe meta access?
            for my $dm (keys %{$CPAN::META->{readwrite}{"CPAN::$class"}}) {
                next unless $CPAN::META->{readwrite}{"CPAN::$class"}{$dm}{incommandcolor};
                CPAN->debug("BUG: $class '$dm' was in command state, resetting");
                delete $CPAN::META->{readwrite}{"CPAN::$class"}{$dm}{incommandcolor};
            }
        }
        if ($GOTOSHELL) {
            $GOTOSHELL = 0; # not too often
            $META->savehist if $CPAN::term && $CPAN::term->can("GetHistory");
            @_ = ($oprompt,"");
            goto &shell;
        }
    }
    soft_chdir_with_alternatives(\@cwd);
}

#-> CPAN::soft_chdir_with_alternatives ;
sub soft_chdir_with_alternatives ($) {
    my($cwd) = @_;
    unless (@$cwd) {
        my $root = File::Spec->rootdir();
        $CPAN::Frontend->mywarn(qq{Warning: no good directory to chdir to!
Trying '$root' as temporary haven.
});
        push @$cwd, $root;
    }
    while () {
        if (chdir $cwd->[0]) {
            return;
        } else {
            if (@$cwd>1) {
                $CPAN::Frontend->mywarn(qq{Could not chdir to "$cwd->[0]": $!
Trying to chdir to "$cwd->[1]" instead.
});
                shift @$cwd;
            } else {
                $CPAN::Frontend->mydie(qq{Could not chdir to "$cwd->[0]": $!});
            }
        }
    }
}

sub _flock {
    my($fh,$mode) = @_;
    if ( $Config::Config{d_flock} || $Config::Config{d_fcntl_can_lock} ) {
        return flock $fh, $mode;
    } elsif (!$Have_warned->{"d_flock"}++) {
        $CPAN::Frontend->mywarn("Your OS does not seem to support locking; continuing and ignoring all locking issues\n");
        $CPAN::Frontend->mysleep(5);
        return 1;
    } else {
        return 1;
    }
}

sub _yaml_module () {
    my $yaml_module = $CPAN::Config->{yaml_module} || "YAML";
    if (
        $yaml_module ne "YAML"
        &&
        !$CPAN::META->has_inst($yaml_module)
       ) {
        # $CPAN::Frontend->mywarn("'$yaml_module' not installed, falling back to 'YAML'\n");
        $yaml_module = "YAML";
    }
    if ($yaml_module eq "YAML"
        &&
        $CPAN::META->has_inst($yaml_module)
        &&
        $YAML::VERSION < 0.60
        &&
        !$Have_warned->{"YAML"}++
       ) {
        $CPAN::Frontend->mywarn("Warning: YAML version '$YAML::VERSION' is too low, please upgrade!\n".
                                "I'll continue but problems are *very* likely to happen.\n"
                               );
        $CPAN::Frontend->mysleep(5);
    }
    return $yaml_module;
}

# CPAN::_yaml_loadfile
sub _yaml_loadfile {
    my($self,$local_file) = @_;
    return +[] unless -s $local_file;
    my $yaml_module = _yaml_module;
    if ($CPAN::META->has_inst($yaml_module)) {
        # temporarly enable yaml code deserialisation
        no strict 'refs';
        # 5.6.2 could not do the local() with the reference
        # so we do it manually instead
        my $old_loadcode = ${"$yaml_module\::LoadCode"};
        ${ "$yaml_module\::LoadCode" } = $CPAN::Config->{yaml_load_code} || 0;

        my ($code, @yaml);
        if ($code = UNIVERSAL::can($yaml_module, "LoadFile")) {
            eval { @yaml = $code->($local_file); };
            if ($@) {
                # this shall not be done by the frontend
                die CPAN::Exception::yaml_process_error->new($yaml_module,$local_file,"parse",$@);
            }
        } elsif ($code = UNIVERSAL::can($yaml_module, "Load")) {
            local *FH;
            open FH, $local_file or die "Could not open '$local_file': $!";
            local $/;
            my $ystream = <FH>;
            eval { @yaml = $code->($ystream); };
            if ($@) {
                # this shall not be done by the frontend
                die CPAN::Exception::yaml_process_error->new($yaml_module,$local_file,"parse",$@);
            }
        }
        ${"$yaml_module\::LoadCode"} = $old_loadcode;
        return \@yaml;
    } else {
        # this shall not be done by the frontend
        die CPAN::Exception::yaml_not_installed->new($yaml_module, $local_file, "parse");
    }
    return +[];
}

# CPAN::_yaml_dumpfile
sub _yaml_dumpfile {
    my($self,$local_file,@what) = @_;
    my $yaml_module = _yaml_module;
    if ($CPAN::META->has_inst($yaml_module)) {
        my $code;
        if (UNIVERSAL::isa($local_file, "FileHandle")) {
            $code = UNIVERSAL::can($yaml_module, "Dump");
            eval { print $local_file $code->(@what) };
        } elsif ($code = UNIVERSAL::can($yaml_module, "DumpFile")) {
            eval { $code->($local_file,@what); };
        } elsif ($code = UNIVERSAL::can($yaml_module, "Dump")) {
            local *FH;
            open FH, ">$local_file" or die "Could not open '$local_file': $!";
            print FH $code->(@what);
        }
        if ($@) {
            die CPAN::Exception::yaml_process_error->new($yaml_module,$local_file,"dump",$@);
        }
    } else {
        if (UNIVERSAL::isa($local_file, "FileHandle")) {
            # I think this case does not justify a warning at all
        } else {
            die CPAN::Exception::yaml_not_installed->new($yaml_module, $local_file, "dump");
        }
    }
}

sub _init_sqlite () {
    unless ($CPAN::META->has_inst("CPAN::SQLite")) {
        $CPAN::Frontend->mywarn(qq{CPAN::SQLite not installed, trying to work without\n})
            unless $Have_warned->{"CPAN::SQLite"}++;
        return;
    }
    require CPAN::SQLite::META; # not needed since CVS version of 2006-12-17
    $CPAN::SQLite ||= CPAN::SQLite::META->new($CPAN::META);
}

{
    my $negative_cache = {};
    sub _sqlite_running {
        if ($negative_cache->{time} && time < $negative_cache->{time} + 60) {
            # need to cache the result, otherwise too slow
            return $negative_cache->{fact};
        } else {
            $negative_cache = {}; # reset
        }
        my $ret = $CPAN::Config->{use_sqlite} && ($CPAN::SQLite || _init_sqlite());
        return $ret if $ret; # fast anyway
        $negative_cache->{time} = time;
        return $negative_cache->{fact} = $ret;
    }
}



package CPAN::Distribution;
use strict;
@CPAN::Distribution::ISA = qw(CPAN::InfoObj);

use vars qw(
            $VERSION
);
$VERSION = "5.5";

package CPAN::Bundle;
use strict;
@CPAN::Bundle::ISA = qw(CPAN::Module);

package CPAN::Module;
use strict;
@CPAN::Module::ISA = qw(CPAN::InfoObj);

use vars qw(
            $VERSION
);
$VERSION = "5.5";

package CPAN::Exception::RecursiveDependency;
use strict;
use overload '""' => "as_string";

use vars qw(
            $VERSION
);
$VERSION = "5.5";

# a module sees its distribution (no version)
# a distribution sees its prereqs (which are module names) (usually with versions)
# a bundle sees its module names and/or its distributions (no version)

sub new {
    my($class) = shift;
    my($deps) = shift;
    my (@deps,%seen,$loop_starts_with);
  DCHAIN: for my $dep (@$deps) {
        push @deps, {name => $dep, display_as => $dep};
        if ($seen{$dep}++) {
            $loop_starts_with = $dep;
            last DCHAIN;
        }
    }
    my $in_loop = 0;
    for my $i (0..$#deps) {
        my $x = $deps[$i]{name};
        $in_loop ||= $x eq $loop_starts_with;
        my $xo = CPAN::Shell->expandany($x) or next;
        if ($xo->isa("CPAN::Module")) {
            my $have = $xo->inst_version || "N/A";
            my($want,$d,$want_type);
            if ($i>0 and $d = $deps[$i-1]{name}) {
                my $do = CPAN::Shell->expandany($d);
                $want = $do->{prereq_pm}{requires}{$x};
                if (defined $want) {
                    $want_type = "requires: ";
                } else {
                    $want = $do->{prereq_pm}{build_requires}{$x};
                    if (defined $want) {
                        $want_type = "build_requires: ";
                    } else {
                        $want_type = "unknown status";
                        $want = "???";
                    }
                }
            } else {
                $want = $xo->cpan_version;
                $want_type = "want: ";
            }
            $deps[$i]{have} = $have;
            $deps[$i]{want_type} = $want_type;
            $deps[$i]{want} = $want;
            $deps[$i]{display_as} = "$x (have: $have; $want_type$want)";
        } elsif ($xo->isa("CPAN::Distribution")) {
            $deps[$i]{display_as} = $xo->pretty_id;
            if ($in_loop) {
                $xo->{make} = CPAN::Distrostatus->new("NO cannot resolve circular dependency");
            } else {
                $xo->{make} = CPAN::Distrostatus->new("NO one dependency ($loop_starts_with) is a circular dependency");
            }
            $xo->store_persistent_state; # otherwise I will not reach
                                         # all involved parties for
                                         # the next session
        }
    }
    bless { deps => \@deps }, $class;
}

sub as_string {
    my($self) = shift;
    my $ret = "\nRecursive dependency detected:\n    ";
    $ret .= join("\n => ", map {$_->{display_as}} @{$self->{deps}});
    $ret .= ".\nCannot resolve.\n";
    $ret;
}

package CPAN::Exception::yaml_not_installed;
use strict;
use overload '""' => "as_string";

sub new {
    my($class,$module,$file,$during) = @_;
    bless { module => $module, file => $file, during => $during }, $class;
}

sub as_string {
    my($self) = shift;
    "'$self->{module}' not installed, cannot $self->{during} '$self->{file}'\n";
}

package CPAN::Exception::yaml_process_error;
use strict;
use overload '""' => "as_string";

sub new {
    my($class,$module,$file,$during,$error) = @_;
    # my $at = Carp::longmess(""); # XXX find something more beautiful
    bless { module => $module,
            file => $file,
            during => $during,
            error => $error,
            # at => $at,
          }, $class;
}

sub as_string {
    my($self) = shift;
    if ($self->{during}) {
        if ($self->{file}) {
            if ($self->{module}) {
                if ($self->{error}) {
                    return "Alert: While trying to '$self->{during}' YAML file\n".
                        " '$self->{file}'\n".
                            "with '$self->{module}' the following error was encountered:\n".
                                "  $self->{error}\n";
                } else {
                    return "Alert: While trying to '$self->{during}' YAML file\n".
                        " '$self->{file}'\n".
                            "with '$self->{module}' some unknown error was encountered\n";
                }
            } else {
                return "Alert: While trying to '$self->{during}' YAML file\n".
                    " '$self->{file}'\n".
                        "some unknown error was encountered\n";
            }
        } else {
            return "Alert: While trying to '$self->{during}' some YAML file\n".
                    "some unknown error was encountered\n";
        }
    } else {
        return "Alert: unknown error encountered\n";
    }
}

package CPAN::Prompt; use overload '""' => "as_string";
use vars qw($prompt);
$prompt = "cpan> ";
$CPAN::CurrentCommandId ||= 0;
sub new {
    bless {}, shift;
}
sub as_string {
    my $word = "cpan";
    unless ($CPAN::META->{LOCK}) {
        $word = "nolock_cpan";
    }
    if ($CPAN::Config->{commandnumber_in_prompt}) {
        sprintf "$word\[%d]> ", $CPAN::CurrentCommandId;
    } else {
        "$word> ";
    }
}

package CPAN::URL; use overload '""' => "as_string", fallback => 1;
# accessors: TEXT(the url string), FROM(DEF=>defaultlist,USER=>urllist),
# planned are things like age or quality
sub new {
    my($class,%args) = @_;
    bless {
           %args
          }, $class;
}
sub as_string {
    my($self) = @_;
    $self->text;
}
sub text {
    my($self,$set) = @_;
    if (defined $set) {
        $self->{TEXT} = $set;
    }
    $self->{TEXT};
}

package CPAN::Distrostatus;
use overload '""' => "as_string",
    fallback => 1;
use vars qw($something_has_failed_at);
sub new {
    my($class,$arg) = @_;
    my $failed = substr($arg,0,2) eq "NO";
    if ($failed) {
        $something_has_failed_at = $CPAN::CurrentCommandId;
    }
    bless {
           TEXT => $arg,
           FAILED => $failed,
           COMMANDID => $CPAN::CurrentCommandId,
           TIME => time,
          }, $class;
}
sub something_has_just_failed () {
    defined $something_has_failed_at &&
        $something_has_failed_at == $CPAN::CurrentCommandId;
}
sub commandid { shift->{COMMANDID} }
sub failed { shift->{FAILED} }
sub text {
    my($self,$set) = @_;
    if (defined $set) {
        $self->{TEXT} = $set;
    }
    $self->{TEXT};
}
sub as_string {
    my($self) = @_;
    $self->text;
}


package CPAN;
use strict;

$META ||= CPAN->new; # In case we re-eval ourselves we need the ||

# from here on only subs.
################################################################################

sub _perl_fingerprint {
    my($self,$other_fingerprint) = @_;
    my $dll = eval {OS2::DLLname()};
    my $mtime_dll = 0;
    if (defined $dll) {
        $mtime_dll = (-f $dll ? (stat(_))[9] : '-1');
    }
    my $mtime_perl = (-f CPAN::find_perl ? (stat(_))[9] : '-1');
    my $this_fingerprint = {
                            '$^X' => CPAN::find_perl,
                            sitearchexp => $Config::Config{sitearchexp},
                            'mtime_$^X' => $mtime_perl,
                            'mtime_dll' => $mtime_dll,
                           };
    if ($other_fingerprint) {
        if (exists $other_fingerprint->{'stat($^X)'}) { # repair fp from rev. 1.88_57
            $other_fingerprint->{'mtime_$^X'} = $other_fingerprint->{'stat($^X)'}[9];
        }
        # mandatory keys since 1.88_57
        for my $key (qw($^X sitearchexp mtime_dll mtime_$^X)) {
            return unless $other_fingerprint->{$key} eq $this_fingerprint->{$key};
        }
        return 1;
    } else {
        return $this_fingerprint;
    }
}

sub suggest_myconfig () {
  SUGGEST_MYCONFIG: if(!$INC{'CPAN/MyConfig.pm'}) {
        $CPAN::Frontend->myprint("You don't seem to have a user ".
                                 "configuration (MyConfig.pm) yet.\n");
        my $new = CPAN::Shell::colorable_makemaker_prompt("Do you want to create a ".
                                              "user configuration now? (Y/n)",
                                              "yes");
        if($new =~ m{^y}i) {
            CPAN::Shell->mkmyconfig();
            return &checklock;
        } else {
            $CPAN::Frontend->mydie("OK, giving up.");
        }
    }
}

#-> sub CPAN::all_objects ;
sub all_objects {
    my($mgr,$class) = @_;
    CPAN::HandleConfig->load unless $CPAN::Config_loaded++;
    CPAN->debug("mgr[$mgr] class[$class]") if $CPAN::DEBUG;
    CPAN::Index->reload;
    values %{ $META->{readwrite}{$class} }; # unsafe meta access, ok
}

# Called by shell, not in batch mode. In batch mode I see no risk in
# having many processes updating something as installations are
# continually checked at runtime. In shell mode I suspect it is
# unintentional to open more than one shell at a time

#-> sub CPAN::checklock ;
sub checklock {
    my($self) = @_;
    my $lockfile = File::Spec->catfile($CPAN::Config->{cpan_home},".lock");
    if (-f $lockfile && -M _ > 0) {
        my $fh = FileHandle->new($lockfile) or
            $CPAN::Frontend->mydie("Could not open lockfile '$lockfile': $!");
        my $otherpid  = <$fh>;
        my $otherhost = <$fh>;
        $fh->close;
        if (defined $otherpid && $otherpid) {
            chomp $otherpid;
        }
        if (defined $otherhost && $otherhost) {
            chomp $otherhost;
        }
        my $thishost  = hostname();
        if (defined $otherhost && defined $thishost &&
            $otherhost ne '' && $thishost ne '' &&
            $otherhost ne $thishost) {
            $CPAN::Frontend->mydie(sprintf("CPAN.pm panic: Lockfile '$lockfile'\n".
                                           "reports other host $otherhost and other ".
                                           "process $otherpid.\n".
                                           "Cannot proceed.\n"));
        } elsif ($RUN_DEGRADED) {
            $CPAN::Frontend->mywarn("Running in downgraded mode (experimental)\n");
        } elsif (defined $otherpid && $otherpid) {
            return if $$ == $otherpid; # should never happen
            $CPAN::Frontend->mywarn(
                                    qq{
There seems to be running another CPAN process (pid $otherpid).  Contacting...
});
            if (kill 0, $otherpid or $!{EPERM}) {
                $CPAN::Frontend->mywarn(qq{Other job is running.\n});
                my($ans) =
                    CPAN::Shell::colorable_makemaker_prompt
                        (qq{Shall I try to run in downgraded }.
                        qq{mode? (Y/n)},"y");
                if ($ans =~ /^y/i) {
                    $CPAN::Frontend->mywarn("Running in downgraded mode (experimental).
Please report if something unexpected happens\n");
                    $RUN_DEGRADED = 1;
                    for ($CPAN::Config) {
                        # XXX
                        # $_->{build_dir_reuse} = 0; # 2006-11-17 akoenig Why was that?
                        $_->{commandnumber_in_prompt} = 0; # visibility
                        $_->{histfile}       = "";  # who should win otherwise?
                        $_->{cache_metadata} = 0;   # better would be a lock?
                        $_->{use_sqlite}     = 0;   # better would be a write lock!
                        $_->{auto_commit}    = 0;   # we are violent, do not persist
                        $_->{test_report}    = 0;   # Oliver Paukstadt had sent wrong reports in degraded mode
                    }
                } else {
                    $CPAN::Frontend->mydie("
You may want to kill the other job and delete the lockfile. On UNIX try:
    kill $otherpid
    rm $lockfile
");
                }
            } elsif (-w $lockfile) {
                my($ans) =
                    CPAN::Shell::colorable_makemaker_prompt
                        (qq{Other job not responding. Shall I overwrite }.
                        qq{the lockfile '$lockfile'? (Y/n)},"y");
            $CPAN::Frontend->myexit("Ok, bye\n")
                unless $ans =~ /^y/i;
            } else {
                Carp::croak(
                    qq{Lockfile '$lockfile' not writable by you. }.
                    qq{Cannot proceed.\n}.
                    qq{    On UNIX try:\n}.
                    qq{    rm '$lockfile'\n}.
                    qq{  and then rerun us.\n}
                );
            }
        } else {
            $CPAN::Frontend->mydie(sprintf("CPAN.pm panic: Found invalid lockfile ".
                                           "'$lockfile', please remove. Cannot proceed.\n"));
        }
    }
    my $dotcpan = $CPAN::Config->{cpan_home};
    eval { File::Path::mkpath($dotcpan);};
    if ($@) {
        # A special case at least for Jarkko.
        my $firsterror = $@;
        my $seconderror;
        my $symlinkcpan;
        if (-l $dotcpan) {
            $symlinkcpan = readlink $dotcpan;
            die "readlink $dotcpan failed: $!" unless defined $symlinkcpan;
            eval { File::Path::mkpath($symlinkcpan); };
            if ($@) {
                $seconderror = $@;
            } else {
                $CPAN::Frontend->mywarn(qq{
Working directory $symlinkcpan created.
});
            }
        }
        unless (-d $dotcpan) {
            my $mess = qq{
Your configuration suggests "$dotcpan" as your
CPAN.pm working directory. I could not create this directory due
to this error: $firsterror\n};
            $mess .= qq{
As "$dotcpan" is a symlink to "$symlinkcpan",
I tried to create that, but I failed with this error: $seconderror
} if $seconderror;
            $mess .= qq{
Please make sure the directory exists and is writable.
};
            $CPAN::Frontend->mywarn($mess);
            return suggest_myconfig;
        }
    } # $@ after eval mkpath $dotcpan
    if (0) { # to test what happens when a race condition occurs
        for (reverse 1..10) {
            print $_, "\n";
            sleep 1;
        }
    }
    # locking
    if (!$RUN_DEGRADED && !$self->{LOCKFH}) {
        my $fh;
        unless ($fh = FileHandle->new("+>>$lockfile")) {
            if ($! =~ /Permission/) {
                $CPAN::Frontend->mywarn(qq{

Your configuration suggests that CPAN.pm should use a working
directory of
    $CPAN::Config->{cpan_home}
Unfortunately we could not create the lock file
    $lockfile
due to permission problems.

Please make sure that the configuration variable
    \$CPAN::Config->{cpan_home}
points to a directory where you can write a .lock file. You can set
this variable in either a CPAN/MyConfig.pm or a CPAN/Config.pm in your
\@INC path;
});
                return suggest_myconfig;
            }
        }
        my $sleep = 1;
        while (!CPAN::_flock($fh, LOCK_EX|LOCK_NB)) {
            if ($sleep>10) {
                $CPAN::Frontend->mydie("Giving up\n");
            }
            $CPAN::Frontend->mysleep($sleep++);
            $CPAN::Frontend->mywarn("Could not lock lockfile with flock: $!; retrying\n");
        }

        seek $fh, 0, 0;
        truncate $fh, 0;
        $fh->autoflush(1);
        $fh->print($$, "\n");
        $fh->print(hostname(), "\n");
        $self->{LOCK} = $lockfile;
        $self->{LOCKFH} = $fh;
    }
    $SIG{TERM} = sub {
        my $sig = shift;
        &cleanup;
        $CPAN::Frontend->mydie("Got SIG$sig, leaving");
    };
    $SIG{INT} = sub {
      # no blocks!!!
        my $sig = shift;
        &cleanup if $Signal;
        die "Got yet another signal" if $Signal > 1;
        $CPAN::Frontend->mydie("Got another SIG$sig") if $Signal;
        $CPAN::Frontend->mywarn("Caught SIG$sig, trying to continue\n");
        $Signal++;
    };

#       From: Larry Wall <larry@wall.org>
#       Subject: Re: deprecating SIGDIE
#       To: perl5-porters@perl.org
#       Date: Thu, 30 Sep 1999 14:58:40 -0700 (PDT)
#
#       The original intent of __DIE__ was only to allow you to substitute one
#       kind of death for another on an application-wide basis without respect
#       to whether you were in an eval or not.  As a global backstop, it should
#       not be used any more lightly (or any more heavily :-) than class
#       UNIVERSAL.  Any attempt to build a general exception model on it should
#       be politely squashed.  Any bug that causes every eval {} to have to be
#       modified should be not so politely squashed.
#
#       Those are my current opinions.  It is also my optinion that polite
#       arguments degenerate to personal arguments far too frequently, and that
#       when they do, it's because both people wanted it to, or at least didn't
#       sufficiently want it not to.
#
#       Larry

    # global backstop to cleanup if we should really die
    $SIG{__DIE__} = \&cleanup;
    $self->debug("Signal handler set.") if $CPAN::DEBUG;
}

#-> sub CPAN::DESTROY ;
sub DESTROY {
    &cleanup; # need an eval?
}

#-> sub CPAN::anycwd ;
sub anycwd () {
    my $getcwd;
    $getcwd = $CPAN::Config->{'getcwd'} || 'cwd';
    CPAN->$getcwd();
}

#-> sub CPAN::cwd ;
sub cwd {Cwd::cwd();}

#-> sub CPAN::getcwd ;
sub getcwd {Cwd::getcwd();}

#-> sub CPAN::fastcwd ;
sub fastcwd {Cwd::fastcwd();}

#-> sub CPAN::backtickcwd ;
sub backtickcwd {my $cwd = `cwd`; chomp $cwd; $cwd}

#-> sub CPAN::find_perl ;
sub find_perl () {
    my($perl) = File::Spec->file_name_is_absolute($^X) ? $^X : "";
    unless ($perl) {
        my $candidate = File::Spec->catfile($CPAN::iCwd,$^X);
        $^X = $perl = $candidate if MM->maybe_command($candidate);
    }
    unless ($perl) {
        my ($component,$perl_name);
      DIST_PERLNAME: foreach $perl_name ($^X, 'perl', 'perl5', "perl$]") {
          PATH_COMPONENT: foreach $component (File::Spec->path(),
                                                $Config::Config{'binexp'}) {
                next unless defined($component) && $component;
                my($abs) = File::Spec->catfile($component,$perl_name);
                if (MM->maybe_command($abs)) {
                    $^X = $perl = $abs;
                    last DIST_PERLNAME;
                }
            }
        }
    }
    return $perl;
}


#-> sub CPAN::exists ;
sub exists {
    my($mgr,$class,$id) = @_;
    CPAN::HandleConfig->load unless $CPAN::Config_loaded++;
    CPAN::Index->reload;
    ### Carp::croak "exists called without class argument" unless $class;
    $id ||= "";
    $id =~ s/:+/::/g if $class eq "CPAN::Module";
    my $exists;
    if (CPAN::_sqlite_running) {
        $exists = (exists $META->{readonly}{$class}{$id} or
                   $CPAN::SQLite->set($class, $id));
    } else {
        $exists =  exists $META->{readonly}{$class}{$id};
    }
    $exists ||= exists $META->{readwrite}{$class}{$id}; # unsafe meta access, ok
}

#-> sub CPAN::delete ;
sub delete {
  my($mgr,$class,$id) = @_;
  delete $META->{readonly}{$class}{$id}; # unsafe meta access, ok
  delete $META->{readwrite}{$class}{$id}; # unsafe meta access, ok
}

#-> sub CPAN::has_usable
# has_inst is sometimes too optimistic, we should replace it with this
# has_usable whenever a case is given
sub has_usable {
    my($self,$mod,$message) = @_;
    return 1 if $HAS_USABLE->{$mod};
    my $has_inst = $self->has_inst($mod,$message);
    return unless $has_inst;
    my $usable;
    $usable = {
               LWP => [ # we frequently had "Can't locate object
                        # method "new" via package "LWP::UserAgent" at
                        # (eval 69) line 2006
                       sub {require LWP},
                       sub {require LWP::UserAgent},
                       sub {require HTTP::Request},
                       sub {require URI::URL},
                      ],
               'Net::FTP' => [
                            sub {require Net::FTP},
                            sub {require Net::Config},
                           ],
               'File::HomeDir' => [
                                   sub {require File::HomeDir;
                                        unless (CPAN::Version->vge(File::HomeDir::->VERSION, 0.52)) {
                                            for ("Will not use File::HomeDir, need 0.52\n") {
                                                $CPAN::Frontend->mywarn($_);
                                                die $_;
                                            }
                                        }
                                    },
                                  ],
               'Archive::Tar' => [
                                  sub {require Archive::Tar;
                                       unless (CPAN::Version->vge(Archive::Tar::->VERSION, 1.00)) {
                                            for ("Will not use Archive::Tar, need 1.00\n") {
                                                $CPAN::Frontend->mywarn($_);
                                                die $_;
                                            }
                                       }
                                  },
                                 ],
               'File::Temp' => [
                                # XXX we should probably delete from
                                # %INC too so we can load after we
                                # installed a new enough version --
                                # I'm not sure.
                                sub {require File::Temp;
                                     unless (CPAN::Version->vge(File::Temp::->VERSION,0.16)) {
                                         for ("Will not use File::Temp, need 0.16\n") {
                                                $CPAN::Frontend->mywarn($_);
                                                die $_;
                                         }
                                     }
                                },
                               ]
              };
    if ($usable->{$mod}) {
        for my $c (0..$#{$usable->{$mod}}) {
            my $code = $usable->{$mod}[$c];
            my $ret = eval { &$code() };
            $ret = "" unless defined $ret;
            if ($@) {
                # warn "DEBUG: c[$c]\$\@[$@]ret[$ret]";
                return;
            }
        }
    }
    return $HAS_USABLE->{$mod} = 1;
}

#-> sub CPAN::has_inst
sub has_inst {
    my($self,$mod,$message) = @_;
    Carp::croak("CPAN->has_inst() called without an argument")
        unless defined $mod;
    my %dont = map { $_ => 1 } keys %{$CPAN::META->{dontload_hash}||{}},
        keys %{$CPAN::Config->{dontload_hash}||{}},
            @{$CPAN::Config->{dontload_list}||[]};
    if (defined $message && $message eq "no"  # afair only used by Nox
        ||
        $dont{$mod}
       ) {
      $CPAN::META->{dontload_hash}{$mod}||=1; # unsafe meta access, ok
      return 0;
    }
    my $file = $mod;
    my $obj;
    $file =~ s|::|/|g;
    $file .= ".pm";
    if ($INC{$file}) {
        # checking %INC is wrong, because $INC{LWP} may be true
        # although $INC{"URI/URL.pm"} may have failed. But as
        # I really want to say "bla loaded OK", I have to somehow
        # cache results.
        ### warn "$file in %INC"; #debug
        return 1;
    } elsif (eval { require $file }) {
        # eval is good: if we haven't yet read the database it's
        # perfect and if we have installed the module in the meantime,
        # it tries again. The second require is only a NOOP returning
        # 1 if we had success, otherwise it's retrying

        my $mtime = (stat $INC{$file})[9];
        # privileged files loaded by has_inst; Note: we use $mtime
        # as a proxy for a checksum.
        $CPAN::Shell::reload->{$file} = $mtime;
        my $v = eval "\$$mod\::VERSION";
        $v = $v ? " (v$v)" : "";
        CPAN::Shell->optprint("load_module","CPAN: $mod loaded ok$v\n");
        if ($mod eq "CPAN::WAIT") {
            push @CPAN::Shell::ISA, 'CPAN::WAIT';
        }
        return 1;
    } elsif ($mod eq "Net::FTP") {
        $CPAN::Frontend->mywarn(qq{
  Please, install Net::FTP as soon as possible. CPAN.pm installs it for you
  if you just type
      install Bundle::libnet

}) unless $Have_warned->{"Net::FTP"}++;
        $CPAN::Frontend->mysleep(3);
    } elsif ($mod eq "Digest::SHA") {
        if ($Have_warned->{"Digest::SHA"}++) {
            $CPAN::Frontend->mywarn(qq{CPAN: checksum security checks disabled }.
                                     qq{because Digest::SHA not installed.\n});
        } else {
            $CPAN::Frontend->mywarn(qq{
  CPAN: checksum security checks disabled because Digest::SHA not installed.
  Please consider installing the Digest::SHA module.

});
            $CPAN::Frontend->mysleep(2);
        }
    } elsif ($mod eq "Module::Signature") {
        # NOT prefs_lookup, we are not a distro
        my $check_sigs = $CPAN::Config->{check_sigs};
        if (not $check_sigs) {
            # they do not want us:-(
        } elsif (not $Have_warned->{"Module::Signature"}++) {
            # No point in complaining unless the user can
            # reasonably install and use it.
            if (eval { require Crypt::OpenPGP; 1 } ||
                (
                 defined $CPAN::Config->{'gpg'}
                 &&
                 $CPAN::Config->{'gpg'} =~ /\S/
                )
               ) {
                $CPAN::Frontend->mywarn(qq{
  CPAN: Module::Signature security checks disabled because Module::Signature
  not installed.  Please consider installing the Module::Signature module.
  You may also need to be able to connect over the Internet to the public
  keyservers like pgp.mit.edu (port 11371).

});
                $CPAN::Frontend->mysleep(2);
            }
        }
    } else {
        delete $INC{$file}; # if it inc'd LWP but failed during, say, URI
    }
    return 0;
}

#-> sub CPAN::instance ;
sub instance {
    my($mgr,$class,$id) = @_;
    CPAN::Index->reload;
    $id ||= "";
    # unsafe meta access, ok?
    return $META->{readwrite}{$class}{$id} if exists $META->{readwrite}{$class}{$id};
    $META->{readwrite}{$class}{$id} ||= $class->new(ID => $id);
}

#-> sub CPAN::new ;
sub new {
    bless {}, shift;
}

#-> sub CPAN::cleanup ;
sub cleanup {
  # warn "cleanup called with arg[@_] End[$CPAN::End] Signal[$Signal]";
  local $SIG{__DIE__} = '';
  my($message) = @_;
  my $i = 0;
  my $ineval = 0;
  my($subroutine);
  while ((undef,undef,undef,$subroutine) = caller(++$i)) {
      $ineval = 1, last if
        $subroutine eq '(eval)';
  }
  return if $ineval && !$CPAN::End;
  return unless defined $META->{LOCK};
  return unless -f $META->{LOCK};
  $META->savehist;
  close $META->{LOCKFH};
  unlink $META->{LOCK};
  # require Carp;
  # Carp::cluck("DEBUGGING");
  if ( $CPAN::CONFIG_DIRTY ) {
      $CPAN::Frontend->mywarn("Warning: Configuration not saved.\n");
  }
  $CPAN::Frontend->myprint("Lockfile removed.\n");
}

#-> sub CPAN::readhist
sub readhist {
    my($self,$term,$histfile) = @_;
    my $histsize = $CPAN::Config->{'histsize'} || 100;
    $term->Attribs->{'MaxHistorySize'} = $histsize if (defined($term->Attribs->{'MaxHistorySize'}));
    my($fh) = FileHandle->new;
    open $fh, "<$histfile" or return;
    local $/ = "\n";
    while (<$fh>) {
        chomp;
        $term->AddHistory($_);
    }
    close $fh;
}

#-> sub CPAN::savehist
sub savehist {
    my($self) = @_;
    my($histfile,$histsize);
    unless ($histfile = $CPAN::Config->{'histfile'}) {
        $CPAN::Frontend->mywarn("No history written (no histfile specified).\n");
        return;
    }
    $histsize = $CPAN::Config->{'histsize'} || 100;
    if ($CPAN::term) {
        unless ($CPAN::term->can("GetHistory")) {
            $CPAN::Frontend->mywarn("Terminal does not support GetHistory.\n");
            return;
        }
    } else {
        return;
    }
    my @h = $CPAN::term->GetHistory;
    splice @h, 0, @h-$histsize if @h>$histsize;
    my($fh) = FileHandle->new;
    open $fh, ">$histfile" or $CPAN::Frontend->mydie("Couldn't open >$histfile: $!");
    local $\ = local $, = "\n";
    print $fh @h;
    close $fh;
}

#-> sub CPAN::is_tested
sub is_tested {
    my($self,$what,$when) = @_;
    unless ($what) {
        Carp::cluck("DEBUG: empty what");
        return;
    }
    $self->{is_tested}{$what} = $when;
}

#-> sub CPAN::reset_tested
# forget all distributions tested -- resets what gets included in PERL5LIB
sub reset_tested {
    my ($self) = @_;
    $self->{is_tested} = {};
}

#-> sub CPAN::is_installed
# unsets the is_tested flag: as soon as the thing is installed, it is
# not needed in set_perl5lib anymore
sub is_installed {
    my($self,$what) = @_;
    delete $self->{is_tested}{$what};
}

sub _list_sorted_descending_is_tested {
    my($self) = @_;
    sort
        { ($self->{is_tested}{$b}||0) <=> ($self->{is_tested}{$a}||0) }
            keys %{$self->{is_tested}}
}

#-> sub CPAN::set_perl5lib
# Notes on max environment variable length:
#   - Win32 : XP or later, 8191; Win2000 or NT4, 2047
{
my $fh;
sub set_perl5lib {
    my($self,$for) = @_;
    unless ($for) {
        (undef,undef,undef,$for) = caller(1);
        $for =~ s/.*://;
    }
    $self->{is_tested} ||= {};
    return unless %{$self->{is_tested}};
    my $env = $ENV{PERL5LIB};
    $env = $ENV{PERLLIB} unless defined $env;
    my @env;
    push @env, split /\Q$Config::Config{path_sep}\E/, $env if defined $env and length $env;
    #my @dirs = map {("$_/blib/arch", "$_/blib/lib")} keys %{$self->{is_tested}};
    #$CPAN::Frontend->myprint("Prepending @dirs to PERL5LIB.\n");

    my @dirs = map {("$_/blib/arch", "$_/blib/lib")} $self->_list_sorted_descending_is_tested;
    return if !@dirs;

    if (@dirs < 12) {
        $CPAN::Frontend->optprint('perl5lib', "Prepending @dirs to PERL5LIB for '$for'\n");
        $ENV{PERL5LIB} = join $Config::Config{path_sep}, @dirs, @env;
    } elsif (@dirs < 24 ) {
        my @d = map {my $cp = $_;
                     $cp =~ s/^\Q$CPAN::Config->{build_dir}\E/%BUILDDIR%/;
                     $cp
                 } @dirs;
        $CPAN::Frontend->optprint('perl5lib', "Prepending @d to PERL5LIB; ".
                                 "%BUILDDIR%=$CPAN::Config->{build_dir} ".
                                 "for '$for'\n"
                                );
        $ENV{PERL5LIB} = join $Config::Config{path_sep}, @dirs, @env;
    } else {
        my $cnt = keys %{$self->{is_tested}};
        $CPAN::Frontend->optprint('perl5lib', "Prepending blib/arch and blib/lib of ".
                                 "$cnt build dirs to PERL5LIB; ".
                                 "for '$for'\n"
                                );
        $ENV{PERL5LIB} = join $Config::Config{path_sep}, @dirs, @env;
    }
}}

package CPAN::Distribution;
use strict;
use Cwd qw(chdir);
use CPAN::Distroprefs;

# Accessors
sub cpan_comment {
    my $self = shift;
    my $ro = $self->ro or return;
    $ro->{CPAN_COMMENT}
}

#-> CPAN::Distribution::undelay
sub undelay {
    my $self = shift;
    for my $delayer (
                     "configure_requires_later",
                     "configure_requires_later_for",
                     "later",
                     "later_for",
                    ) {
        delete $self->{$delayer};
    }
}

#-> CPAN::Distribution::is_dot_dist
sub is_dot_dist {
    my($self) = @_;
    return substr($self->id,-1,1) eq ".";
}

# add the A/AN/ stuff
#-> CPAN::Distribution::normalize
sub normalize {
    my($self,$s) = @_;
    $s = $self->id unless defined $s;
    if (substr($s,-1,1) eq ".") {
        # using a global because we are sometimes called as static method
        if (!$CPAN::META->{LOCK}
            && !$CPAN::Have_warned->{"$s is unlocked"}++
           ) {
            $CPAN::Frontend->mywarn("You are visiting the local directory
  '$s'
  without lock, take care that concurrent processes do not do likewise.\n");
            $CPAN::Frontend->mysleep(1);
        }
        if ($s eq ".") {
            $s = "$CPAN::iCwd/.";
        } elsif (File::Spec->file_name_is_absolute($s)) {
        } elsif (File::Spec->can("rel2abs")) {
            $s = File::Spec->rel2abs($s);
        } else {
            $CPAN::Frontend->mydie("Your File::Spec is too old, please upgrade File::Spec");
        }
        CPAN->debug("s[$s]") if $CPAN::DEBUG;
        unless ($CPAN::META->exists("CPAN::Distribution", $s)) {
            for ($CPAN::META->instance("CPAN::Distribution", $s)) {
                $_->{build_dir} = $s;
                $_->{archived} = "local_directory";
                $_->{unwrapped} = CPAN::Distrostatus->new("YES -- local_directory");
            }
        }
    } elsif (
        $s =~ tr|/|| == 1
        or
        $s !~ m|[A-Z]/[A-Z-]{2}/[A-Z-]{2,}/|
       ) {
        return $s if $s =~ m:^N/A|^Contact Author: ;
        $s =~ s|^(.)(.)([^/]*/)(.+)$|$1/$1$2/$1$2$3$4|;
        CPAN->debug("s[$s]") if $CPAN::DEBUG;
    }
    $s;
}

#-> sub CPAN::Distribution::author ;
sub author {
    my($self) = @_;
    my($authorid);
    if (substr($self->id,-1,1) eq ".") {
        $authorid = "LOCAL";
    } else {
        ($authorid) = $self->pretty_id =~ /^([\w\-]+)/;
    }
    CPAN::Shell->expand("Author",$authorid);
}

# tries to get the yaml from CPAN instead of the distro itself:
# EXPERIMENTAL, UNDOCUMENTED AND UNTESTED, for Tels
sub fast_yaml {
    my($self) = @_;
    my $meta = $self->pretty_id;
    $meta =~ s/\.(tar.gz|tgz|zip|tar.bz2)/.meta/;
    my(@ls) = CPAN::Shell->globls($meta);
    my $norm = $self->normalize($meta);

    my($local_file);
    my($local_wanted) =
        File::Spec->catfile(
                            $CPAN::Config->{keep_source_where},
                            "authors",
                            "id",
                            split(/\//,$norm)
                           );
    $self->debug("Doing localize") if $CPAN::DEBUG;
    unless ($local_file =
            CPAN::FTP->localize("authors/id/$norm",
                                $local_wanted)) {
        $CPAN::Frontend->mydie("Giving up on downloading yaml file '$local_wanted'\n");
    }
    my $yaml = CPAN->_yaml_loadfile($local_file)->[0];
}

#-> sub CPAN::Distribution::cpan_userid
sub cpan_userid {
    my $self = shift;
    if ($self->{ID} =~ m{[A-Z]/[A-Z\-]{2}/([A-Z\-]+)/}) {
        return $1;
    }
    return $self->SUPER::cpan_userid;
}

#-> sub CPAN::Distribution::pretty_id
sub pretty_id {
    my $self = shift;
    my $id = $self->id;
    return $id unless $id =~ m|^./../|;
    substr($id,5);
}

#-> sub CPAN::Distribution::base_id
sub base_id {
    my $self = shift;
    my $id = $self->pretty_id();
    my $base_id = File::Basename::basename($id);
    $base_id =~ s{\.(?:tar\.(bz2|gz|Z)|t(?:gz|bz)|zip)$}{}i;
    return $base_id;
}

#-> sub CPAN::Distribution::tested_ok_but_not_installed
sub tested_ok_but_not_installed {
    my $self = shift;
    return (
           $self->{make_test}
        && $self->{build_dir}
        && (UNIVERSAL::can($self->{make_test},"failed") ?
             ! $self->{make_test}->failed :
             $self->{make_test} =~ /^YES/
            )
        && (
            !$self->{install}
            ||
            $self->{install}->failed
           )
    ); 
}


# mark as dirty/clean for the sake of recursion detection. $color=1
# means "in use", $color=0 means "not in use anymore". $color=2 means
# we have determined prereqs now and thus insist on passing this
# through (at least) once again.

#-> sub CPAN::Distribution::color_cmd_tmps ;
sub color_cmd_tmps {
    my($self) = shift;
    my($depth) = shift || 0;
    my($color) = shift || 0;
    my($ancestors) = shift || [];
    # a distribution needs to recurse into its prereq_pms

    return if exists $self->{incommandcolor}
        && $color==1
        && $self->{incommandcolor}==$color;
    if ($depth>=$CPAN::MAX_RECURSION) {
        die(CPAN::Exception::RecursiveDependency->new($ancestors));
    }
    # warn "color_cmd_tmps $depth $color " . $self->id; # sleep 1;
    my $prereq_pm = $self->prereq_pm;
    if (defined $prereq_pm) {
      PREREQ: for my $pre (keys %{$prereq_pm->{requires}||{}},
                           keys %{$prereq_pm->{build_requires}||{}}) {
            next PREREQ if $pre eq "perl";
            my $premo;
            unless ($premo = CPAN::Shell->expand("Module",$pre)) {
                $CPAN::Frontend->mywarn("prerequisite module[$pre] not known\n");
                $CPAN::Frontend->mysleep(2);
                next PREREQ;
            }
            $premo->color_cmd_tmps($depth+1,$color,[@$ancestors, $self->id]);
        }
    }
    if ($color==0) {
        delete $self->{sponsored_mods};

        # as we are at the end of a command, we'll give up this
        # reminder of a broken test. Other commands may test this guy
        # again. Maybe 'badtestcnt' should be renamed to
        # 'make_test_failed_within_command'?
        delete $self->{badtestcnt};
    }
    $self->{incommandcolor} = $color;
}

#-> sub CPAN::Distribution::as_string ;
sub as_string {
    my $self = shift;
    $self->containsmods;
    $self->upload_date;
    $self->SUPER::as_string(@_);
}

#-> sub CPAN::Distribution::containsmods ;
sub containsmods {
    my $self = shift;
    return keys %{$self->{CONTAINSMODS}} if exists $self->{CONTAINSMODS};
    my $dist_id = $self->{ID};
    for my $mod ($CPAN::META->all_objects("CPAN::Module")) {
        my $mod_file = $mod->cpan_file or next;
        my $mod_id = $mod->{ID} or next;
        # warn "mod_file[$mod_file] dist_id[$dist_id] mod_id[$mod_id]";
        # sleep 1;
        if ($CPAN::Signal) {
            delete $self->{CONTAINSMODS};
            return;
        }
        $self->{CONTAINSMODS}{$mod_id} = undef if $mod_file eq $dist_id;
    }
    keys %{$self->{CONTAINSMODS}||={}};
}

#-> sub CPAN::Distribution::upload_date ;
sub upload_date {
    my $self = shift;
    return $self->{UPLOAD_DATE} if exists $self->{UPLOAD_DATE};
    my(@local_wanted) = split(/\//,$self->id);
    my $filename = pop @local_wanted;
    push @local_wanted, "CHECKSUMS";
    my $author = CPAN::Shell->expand("Author",$self->cpan_userid);
    return unless $author;
    my @dl = $author->dir_listing(\@local_wanted,0,$CPAN::Config->{show_upload_date});
    return unless @dl;
    my($dirent) = grep { $_->[2] eq $filename } @dl;
    # warn sprintf "dirent[%s]id[%s]", $dirent, $self->id;
    return unless $dirent->[1];
    return $self->{UPLOAD_DATE} = $dirent->[1];
}

#-> sub CPAN::Distribution::uptodate ;
sub uptodate {
    my($self) = @_;
    my $c;
    foreach $c ($self->containsmods) {
        my $obj = CPAN::Shell->expandany($c);
        unless ($obj->uptodate) {
            my $id = $self->pretty_id;
            $self->debug("$id not uptodate due to $c") if $CPAN::DEBUG;
            return 0;
        }
    }
    return 1;
}

#-> sub CPAN::Distribution::called_for ;
sub called_for {
    my($self,$id) = @_;
    $self->{CALLED_FOR} = $id if defined $id;
    return $self->{CALLED_FOR};
}

#-> sub CPAN::Distribution::get ;
sub get {
    my($self) = @_;
    $self->debug("checking goto id[$self->{ID}]") if $CPAN::DEBUG;
    if (my $goto = $self->prefs->{goto}) {
        $CPAN::Frontend->mywarn
            (sprintf(
                     "delegating to '%s' as specified in prefs file '%s' doc %d\n",
                     $goto,
                     $self->{prefs_file},
                     $self->{prefs_file_doc},
                    ));
        return $self->goto($goto);
    }
    local $ENV{PERL5LIB} = defined($ENV{PERL5LIB})
                           ? $ENV{PERL5LIB}
                           : ($ENV{PERLLIB} || "");
    local $ENV{PERL5OPT} = defined $ENV{PERL5OPT} ? $ENV{PERL5OPT} : "";
    $CPAN::META->set_perl5lib;
    local $ENV{MAKEFLAGS}; # protect us from outer make calls

  EXCUSE: {
        my @e;
        my $goodbye_message;
        $self->debug("checking disabled id[$self->{ID}]") if $CPAN::DEBUG;
        if ($self->prefs->{disabled} && ! $self->{force_update}) {
            my $why = sprintf(
                              "Disabled via prefs file '%s' doc %d",
                              $self->{prefs_file},
                              $self->{prefs_file_doc},
                             );
            push @e, $why;
            $self->{unwrapped} = CPAN::Distrostatus->new("NO $why");
            $goodbye_message = "[disabled] -- NA $why";
            # note: not intended to be persistent but at least visible
            # during this session
        } else {
            if (exists $self->{build_dir} && -d $self->{build_dir}
                && ($self->{modulebuild}||$self->{writemakefile})
               ) {
                # this deserves print, not warn:
                $CPAN::Frontend->myprint("  Has already been unwrapped into directory ".
                                         "$self->{build_dir}\n"
                                        );
                return 1;
            }

            # although we talk about 'force' we shall not test on
            # force directly. New model of force tries to refrain from
            # direct checking of force.
            exists $self->{unwrapped} and (
                                           UNIVERSAL::can($self->{unwrapped},"failed") ?
                                           $self->{unwrapped}->failed :
                                           $self->{unwrapped} =~ /^NO/
                                          )
                and push @e, "Unwrapping had some problem, won't try again without force";
        }
        if (@e) {
            $CPAN::Frontend->mywarn(join "", map {"$_\n"} @e);
            if ($goodbye_message) {
                 $self->goodbye($goodbye_message);
            }
            return;
        }
    }
    my $sub_wd = CPAN::anycwd(); # for cleaning up as good as possible

    my($local_file);
    unless ($self->{build_dir} && -d $self->{build_dir}) {
        $self->get_file_onto_local_disk;
        return if $CPAN::Signal;
        $self->check_integrity;
        return if $CPAN::Signal;
        (my $packagedir,$local_file) = $self->run_preps_on_packagedir;
        if (exists $self->{writemakefile} && ref $self->{writemakefile}
           && $self->{writemakefile}->can("failed") &&
           $self->{writemakefile}->failed) {
            return;
        }
        $packagedir ||= $self->{build_dir};
        $self->{build_dir} = $packagedir;
    }

    if ($CPAN::Signal) {
        $self->safe_chdir($sub_wd);
        return;
    }
    return $self->choose_MM_or_MB($local_file);
}

#-> CPAN::Distribution::get_file_onto_local_disk
sub get_file_onto_local_disk {
    my($self) = @_;

    return if $self->is_dot_dist;
    my($local_file);
    my($local_wanted) =
        File::Spec->catfile(
                            $CPAN::Config->{keep_source_where},
                            "authors",
                            "id",
                            split(/\//,$self->id)
                           );

    $self->debug("Doing localize") if $CPAN::DEBUG;
    unless ($local_file =
            CPAN::FTP->localize("authors/id/$self->{ID}",
                                $local_wanted)) {
        my $note = "";
        if ($CPAN::Index::DATE_OF_02) {
            $note = "Note: Current database in memory was generated ".
                "on $CPAN::Index::DATE_OF_02\n";
        }
        $CPAN::Frontend->mydie("Giving up on '$local_wanted'\n$note");
    }

    $self->debug("local_wanted[$local_wanted]local_file[$local_file]") if $CPAN::DEBUG;
    $self->{localfile} = $local_file;
}


#-> CPAN::Distribution::check_integrity
sub check_integrity {
    my($self) = @_;

    return if $self->is_dot_dist;
    if ($CPAN::META->has_inst("Digest::SHA")) {
        $self->debug("Digest::SHA is installed, verifying");
        $self->verifyCHECKSUM;
    } else {
        $self->debug("Digest::SHA is NOT installed");
    }
}

#-> CPAN::Distribution::run_preps_on_packagedir
sub run_preps_on_packagedir {
    my($self) = @_;
    return if $self->is_dot_dist;

    $CPAN::META->{cachemgr} ||= CPAN::CacheMgr->new(); # unsafe meta access, ok
    my $builddir = $CPAN::META->{cachemgr}->dir; # unsafe meta access, ok
    $self->safe_chdir($builddir);
    $self->debug("Removing tmp-$$") if $CPAN::DEBUG;
    File::Path::rmtree("tmp-$$");
    unless (mkdir "tmp-$$", 0755) {
        $CPAN::Frontend->unrecoverable_error(<<EOF);
Couldn't mkdir '$builddir/tmp-$$': $!

Cannot continue: Please find the reason why I cannot make the
directory
$builddir/tmp-$$
and fix the problem, then retry.

EOF
    }
    if ($CPAN::Signal) {
        return;
    }
    $self->safe_chdir("tmp-$$");

    #
    # Unpack the goods
    #
    my $local_file = $self->{localfile};
    my $ct = eval{CPAN::Tarzip->new($local_file)};
    unless ($ct) {
        $self->{unwrapped} = CPAN::Distrostatus->new("NO");
        delete $self->{build_dir};
        return;
    }
    if ($local_file =~ /(\.tar\.(bz2|gz|Z)|\.tgz)(?!\n)\Z/i) {
        $self->{was_uncompressed}++ unless eval{$ct->gtest()};
        $self->untar_me($ct);
    } elsif ( $local_file =~ /\.zip(?!\n)\Z/i ) {
        $self->unzip_me($ct);
    } else {
        $self->{was_uncompressed}++ unless $ct->gtest();
        $local_file = $self->handle_singlefile($local_file);
    }

    # we are still in the tmp directory!
    # Let's check if the package has its own directory.
    my $dh = DirHandle->new(File::Spec->curdir)
        or Carp::croak("Couldn't opendir .: $!");
    my @readdir = grep $_ !~ /^\.\.?(?!\n)\Z/s, $dh->read; ### MAC??
    if (grep { $_ eq "pax_global_header" } @readdir) {
        $CPAN::Frontend->mywarn("Your (un)tar seems to have extracted a file named 'pax_global_header'
from the tarball '$local_file'.
This is almost certainly an error. Please upgrade your tar.
I'll ignore this file for now.
See also http://rt.cpan.org/Ticket/Display.html?id=38932\n");
        $CPAN::Frontend->mysleep(5);
        @readdir = grep { $_ ne "pax_global_header" } @readdir;
    }
    $dh->close;
    my ($packagedir);
    # XXX here we want in each branch File::Temp to protect all build_dir directories
    if (CPAN->has_usable("File::Temp")) {
        my $tdir_base;
        my $from_dir;
        my @dirents;
        if (@readdir == 1 && -d $readdir[0]) {
            $tdir_base = $readdir[0];
            $from_dir = File::Spec->catdir(File::Spec->curdir,$readdir[0]);
            my $dh2;
            unless ($dh2 = DirHandle->new($from_dir)) {
                my($mode) = (stat $from_dir)[2];
                my $why = sprintf
                    (
                     "Couldn't opendir '%s', mode '%o': %s",
                     $from_dir,
                     $mode,
                     $!,
                    );
                $CPAN::Frontend->mywarn("$why\n");
                $self->{writemakefile} = CPAN::Distrostatus->new("NO -- $why");
                return;
            }
            @dirents = grep $_ !~ /^\.\.?(?!\n)\Z/s, $dh2->read; ### MAC??
        } else {
            my $userid = $self->cpan_userid;
            CPAN->debug("userid[$userid]");
            if (!$userid or $userid eq "N/A") {
                $userid = "anon";
            }
            $tdir_base = $userid;
            $from_dir = File::Spec->curdir;
            @dirents = @readdir;
        }
        $packagedir = File::Temp::tempdir(
                                          "$tdir_base-XXXXXX",
                                          DIR => $builddir,
                                          CLEANUP => 0,
                                         );
        my $f;
        for $f (@dirents) { # is already without "." and ".."
            my $from = File::Spec->catdir($from_dir,$f);
            my $to = File::Spec->catdir($packagedir,$f);
            unless (File::Copy::move($from,$to)) {
                my $err = $!;
                $from = File::Spec->rel2abs($from);
                Carp::confess("Couldn't move $from to $to: $err");
            }
        }
    } else { # older code below, still better than nothing when there is no File::Temp
        my($distdir);
        if (@readdir == 1 && -d $readdir[0]) {
            $distdir = $readdir[0];
            $packagedir = File::Spec->catdir($builddir,$distdir);
            $self->debug("packagedir[$packagedir]builddir[$builddir]distdir[$distdir]")
                if $CPAN::DEBUG;
            -d $packagedir and $CPAN::Frontend->myprint("Removing previously used ".
                                                        "$packagedir\n");
            File::Path::rmtree($packagedir);
            unless (File::Copy::move($distdir,$packagedir)) {
                $CPAN::Frontend->unrecoverable_error(<<EOF);
Couldn't move '$distdir' to '$packagedir': $!

Cannot continue: Please find the reason why I cannot move
$builddir/tmp-$$/$distdir
to
$packagedir
and fix the problem, then retry

EOF
            }
            $self->debug(sprintf("moved distdir[%s] to packagedir[%s] -e[%s]-d[%s]",
                                 $distdir,
                                 $packagedir,
                                 -e $packagedir,
                                 -d $packagedir,
                                )) if $CPAN::DEBUG;
        } else {
            my $userid = $self->cpan_userid;
            CPAN->debug("userid[$userid]") if $CPAN::DEBUG;
            if (!$userid or $userid eq "N/A") {
                $userid = "anon";
            }
            my $pragmatic_dir = $userid . '000';
            $pragmatic_dir =~ s/\W_//g;
            $pragmatic_dir++ while -d "../$pragmatic_dir";
            $packagedir = File::Spec->catdir($builddir,$pragmatic_dir);
            $self->debug("packagedir[$packagedir]") if $CPAN::DEBUG;
            File::Path::mkpath($packagedir);
            my($f);
            for $f (@readdir) { # is already without "." and ".."
                my $to = File::Spec->catdir($packagedir,$f);
                File::Copy::move($f,$to) or Carp::confess("Couldn't move $f to $to: $!");
            }
        }
    }
    $self->{build_dir} = $packagedir;
    $self->safe_chdir($builddir);
    File::Path::rmtree("tmp-$$");

    $self->safe_chdir($packagedir);
    $self->_signature_business();
    $self->safe_chdir($builddir);

    return($packagedir,$local_file);
}

#-> sub CPAN::Distribution::parse_meta_yml ;
sub parse_meta_yml {
    my($self) = @_;
    my $build_dir = $self->{build_dir} or die "PANIC: cannot parse yaml without a build_dir";
    my $yaml = File::Spec->catfile($build_dir,"META.yml");
    $self->debug("yaml[$yaml]") if $CPAN::DEBUG;
    return unless -f $yaml;
    my $early_yaml;
    eval {
        require Parse::Metayaml; # hypothetical
        $early_yaml = Parse::Metayaml::LoadFile($yaml)->[0];
    };
    unless ($early_yaml) {
        eval { $early_yaml = CPAN->_yaml_loadfile($yaml)->[0]; };
    }
    unless ($early_yaml) {
        return;
    }
    return $early_yaml;
}

#-> sub CPAN::Distribution::satisfy_requires ;
sub satisfy_requires {
    my ($self) = @_;
    if (my @prereq = $self->unsat_prereq("later")) {
        if ($prereq[0][0] eq "perl") {
            my $need = "requires perl '$prereq[0][1]'";
            my $id = $self->pretty_id;
            $CPAN::Frontend->mywarn("$id $need; you have only $]; giving up\n");
            $self->{make} = CPAN::Distrostatus->new("NO $need");
            $self->store_persistent_state;
            die "[prereq] -- NOT OK\n";
        } else {
            my $follow = eval { $self->follow_prereqs("later",@prereq); };
            if (0) {
            } elsif ($follow) {
                # signal success to the queuerunner
                return 1;
            } elsif ($@ && ref $@ && $@->isa("CPAN::Exception::RecursiveDependency")) {
                $CPAN::Frontend->mywarn($@);
                die "[depend] -- NOT OK\n";
            }
        }
    }
}

#-> sub CPAN::Distribution::satisfy_configure_requires ;
sub satisfy_configure_requires {
    my($self) = @_;
    my $enable_configure_requires = 1;
    if (!$enable_configure_requires) {
        return 1;
        # if we return 1 here, everything is as before we introduced
        # configure_requires that means, things with
        # configure_requires simply fail, all others succeed
    }
    my @prereq = $self->unsat_prereq("configure_requires_later") or return 1;
    if ($self->{configure_requires_later}) {
        for my $k (keys %{$self->{configure_requires_later_for}||{}}) {
            if ($self->{configure_requires_later_for}{$k}>1) {
                # we must not come here a second time
                $CPAN::Frontend->mywarn("Panic: Some prerequisites is not available, please investigate...");
                require YAML::Syck;
                $CPAN::Frontend->mydie
                    (
                     YAML::Syck::Dump
                     ({self=>$self, prereq=>\@prereq})
                    );
            }
        }
    }
    if ($prereq[0][0] eq "perl") {
        my $need = "requires perl '$prereq[0][1]'";
        my $id = $self->pretty_id;
        $CPAN::Frontend->mywarn("$id $need; you have only $]; giving up\n");
        $self->{make} = CPAN::Distrostatus->new("NO $need");
        $self->store_persistent_state;
        return $self->goodbye("[prereq] -- NOT OK");
    } else {
        my $follow = eval {
            $self->follow_prereqs("configure_requires_later", @prereq);
        };
        if (0) {
        } elsif ($follow) {
            return;
        } elsif ($@ && ref $@ && $@->isa("CPAN::Exception::RecursiveDependency")) {
            $CPAN::Frontend->mywarn($@);
            return $self->goodbye("[depend] -- NOT OK");
        }
    }
    die "never reached";
}

#-> sub CPAN::Distribution::choose_MM_or_MB ;
sub choose_MM_or_MB {
    my($self,$local_file) = @_;
    $self->satisfy_configure_requires() or return;
    my($mpl) = File::Spec->catfile($self->{build_dir},"Makefile.PL");
    my($mpl_exists) = -f $mpl;
    unless ($mpl_exists) {
        # NFS has been reported to have racing problems after the
        # renaming of a directory in some environments.
        # This trick helps.
        $CPAN::Frontend->mysleep(1);
        my $mpldh = DirHandle->new($self->{build_dir})
            or Carp::croak("Couldn't opendir $self->{build_dir}: $!");
        $mpl_exists = grep /^Makefile\.PL$/, $mpldh->read;
        $mpldh->close;
    }
    my $prefer_installer = "eumm"; # eumm|mb
    if (-f File::Spec->catfile($self->{build_dir},"Build.PL")) {
        if ($mpl_exists) { # they *can* choose
            if ($CPAN::META->has_inst("Module::Build")) {
                $prefer_installer = CPAN::HandleConfig->prefs_lookup($self,
                                                                     q{prefer_installer});
            }
        } else {
            $prefer_installer = "mb";
        }
    }
    return unless $self->patch;
    if (lc($prefer_installer) eq "rand") {
        $prefer_installer = rand()<.5 ? "eumm" : "mb";
    }
    if (lc($prefer_installer) eq "mb") {
        $self->{modulebuild} = 1;
    } elsif ($self->{archived} eq "patch") {
        # not an edge case, nothing to install for sure
        my $why = "A patch file cannot be installed";
        $CPAN::Frontend->mywarn("Refusing to handle this file: $why\n");
        $self->{writemakefile} = CPAN::Distrostatus->new("NO $why");
    } elsif (! $mpl_exists) {
        $self->_edge_cases($mpl,$local_file);
    }
    if ($self->{build_dir}
        &&
        $CPAN::Config->{build_dir_reuse}
       ) {
        $self->store_persistent_state;
    }
    return $self;
}

#-> CPAN::Distribution::store_persistent_state
sub store_persistent_state {
    my($self) = @_;
    my $dir = $self->{build_dir};
    unless (File::Spec->canonpath(File::Basename::dirname($dir))
            eq File::Spec->canonpath($CPAN::Config->{build_dir})) {
        $CPAN::Frontend->mywarn("Directory '$dir' not below $CPAN::Config->{build_dir}, ".
                                "will not store persistent state\n");
        return;
    }
    my $file = sprintf "%s.yml", $dir;
    my $yaml_module = CPAN::_yaml_module;
    if ($CPAN::META->has_inst($yaml_module)) {
        CPAN->_yaml_dumpfile(
                             $file,
                             {
                              time => time,
                              perl => CPAN::_perl_fingerprint,
                              distribution => $self,
                             }
                            );
    } else {
        $CPAN::Frontend->myprint("Warning (usually harmless): '$yaml_module' not installed, ".
                                "will not store persistent state\n");
    }
}

#-> CPAN::Distribution::try_download
sub try_download {
    my($self,$patch) = @_;
    my $norm = $self->normalize($patch);
    my($local_wanted) =
        File::Spec->catfile(
                            $CPAN::Config->{keep_source_where},
                            "authors",
                            "id",
                            split(/\//,$norm),
                           );
    $self->debug("Doing localize") if $CPAN::DEBUG;
    return CPAN::FTP->localize("authors/id/$norm",
                               $local_wanted);
}

{
    my $stdpatchargs = "";
    #-> CPAN::Distribution::patch
    sub patch {
        my($self) = @_;
        $self->debug("checking patches id[$self->{ID}]") if $CPAN::DEBUG;
        my $patches = $self->prefs->{patches};
        $patches ||= "";
        $self->debug("patches[$patches]") if $CPAN::DEBUG;
        if ($patches) {
            return unless @$patches;
            $self->safe_chdir($self->{build_dir});
            CPAN->debug("patches[$patches]") if $CPAN::DEBUG;
            my $patchbin = $CPAN::Config->{patch};
            unless ($patchbin && length $patchbin) {
                $CPAN::Frontend->mydie("No external patch command configured\n\n".
                                       "Please run 'o conf init /patch/'\n\n");
            }
            unless (MM->maybe_command($patchbin)) {
                $CPAN::Frontend->mydie("No external patch command available\n\n".
                                       "Please run 'o conf init /patch/'\n\n");
            }
            $patchbin = CPAN::HandleConfig->safe_quote($patchbin);
            local $ENV{PATCH_GET} = 0; # formerly known as -g0
            unless ($stdpatchargs) {
                my $system = "$patchbin --version |";
                local *FH;
                open FH, $system or die "Could not fork '$system': $!";
                local $/ = "\n";
                my $pversion;
              PARSEVERSION: while (<FH>) {
                    if (/^patch\s+([\d\.]+)/) {
                        $pversion = $1;
                        last PARSEVERSION;
                    }
                }
                if ($pversion) {
                    $stdpatchargs = "-N --fuzz=3";
                } else {
                    $stdpatchargs = "-N";
                }
            }
            my $countedpatches = @$patches == 1 ? "1 patch" : (scalar @$patches . " patches");
            $CPAN::Frontend->myprint("Going to apply $countedpatches:\n");
            my $patches_dir = $CPAN::Config->{patches_dir};
            for my $patch (@$patches) {
                if ($patches_dir && !File::Spec->file_name_is_absolute($patch)) {
                    my $f = File::Spec->catfile($patches_dir, $patch);
                    $patch = $f if -f $f;
                }
                unless (-f $patch) {
                    if (my $trydl = $self->try_download($patch)) {
                        $patch = $trydl;
                    } else {
                        my $fail = "Could not find patch '$patch'";
                        $CPAN::Frontend->mywarn("$fail; cannot continue\n");
                        $self->{unwrapped} = CPAN::Distrostatus->new("NO -- $fail");
                        delete $self->{build_dir};
                        return;
                    }
                }
                $CPAN::Frontend->myprint("  $patch\n");
                my $readfh = CPAN::Tarzip->TIEHANDLE($patch);

                my $pcommand;
                my $ppp = $self->_patch_p_parameter($readfh);
                if ($ppp eq "applypatch") {
                    $pcommand = "$CPAN::Config->{applypatch} -verbose";
                } else {
                    my $thispatchargs = join " ", $stdpatchargs, $ppp;
                    $pcommand = "$patchbin $thispatchargs";
                }

                $readfh = CPAN::Tarzip->TIEHANDLE($patch); # open again
                my $writefh = FileHandle->new;
                $CPAN::Frontend->myprint("  $pcommand\n");
                unless (open $writefh, "|$pcommand") {
                    my $fail = "Could not fork '$pcommand'";
                    $CPAN::Frontend->mywarn("$fail; cannot continue\n");
                    $self->{unwrapped} = CPAN::Distrostatus->new("NO -- $fail");
                    delete $self->{build_dir};
                    return;
                }
                while (my $x = $readfh->READLINE) {
                    print $writefh $x;
                }
                unless (close $writefh) {
                    my $fail = "Could not apply patch '$patch'";
                    $CPAN::Frontend->mywarn("$fail; cannot continue\n");
                    $self->{unwrapped} = CPAN::Distrostatus->new("NO -- $fail");
                    delete $self->{build_dir};
                    return;
                }
            }
            $self->{patched}++;
        }
        return 1;
    }
}

sub _patch_p_parameter {
    my($self,$fh) = @_;
    my $cnt_files   = 0;
    my $cnt_p0files = 0;
    local($_);
    while ($_ = $fh->READLINE) {
        if (
            $CPAN::Config->{applypatch}
            &&
            /\#\#\#\# ApplyPatch data follows \#\#\#\#/
           ) {
            return "applypatch"
        }
        next unless /^[\*\+]{3}\s(\S+)/;
        my $file = $1;
        $cnt_files++;
        $cnt_p0files++ if -f $file;
        CPAN->debug("file[$file]cnt_files[$cnt_files]cnt_p0files[$cnt_p0files]")
            if $CPAN::DEBUG;
    }
    return "-p1" unless $cnt_files;
    return $cnt_files==$cnt_p0files ? "-p0" : "-p1";
}

#-> sub CPAN::Distribution::_edge_cases
# with "configure" or "Makefile" or single file scripts
sub _edge_cases {
    my($self,$mpl,$local_file) = @_;
    $self->debug(sprintf("makefilepl[%s]anycwd[%s]",
                         $mpl,
                         CPAN::anycwd(),
                        )) if $CPAN::DEBUG;
    my $build_dir = $self->{build_dir};
    my($configure) = File::Spec->catfile($build_dir,"Configure");
    if (-f $configure) {
        # do we have anything to do?
        $self->{configure} = $configure;
    } elsif (-f File::Spec->catfile($build_dir,"Makefile")) {
        $CPAN::Frontend->mywarn(qq{
Package comes with a Makefile and without a Makefile.PL.
We\'ll try to build it with that Makefile then.
});
        $self->{writemakefile} = CPAN::Distrostatus->new("YES");
        $CPAN::Frontend->mysleep(2);
    } else {
        my $cf = $self->called_for || "unknown";
        if ($cf =~ m|/|) {
            $cf =~ s|.*/||;
            $cf =~ s|\W.*||;
        }
        $cf =~ s|[/\\:]||g;     # risk of filesystem damage
        $cf = "unknown" unless length($cf);
        if (my $crud = $self->_contains_crud($build_dir)) {
            my $why = qq{Package contains $crud; not recognized as a perl package, giving up};
            $CPAN::Frontend->mywarn("$why\n");
            $self->{writemakefile} = CPAN::Distrostatus->new(qq{NO -- $why});
            return;
        }
        $CPAN::Frontend->mywarn(qq{Package seems to come without Makefile.PL.
  (The test -f "$mpl" returned false.)
  Writing one on our own (setting NAME to $cf)\a\n});
        $self->{had_no_makefile_pl}++;
        $CPAN::Frontend->mysleep(3);

        # Writing our own Makefile.PL

        my $exefile_stanza = "";
        if ($self->{archived} eq "maybe_pl") {
            $exefile_stanza = $self->_exefile_stanza($build_dir,$local_file);
        }

        my $fh = FileHandle->new;
        $fh->open(">$mpl")
            or Carp::croak("Could not open >$mpl: $!");
        $fh->print(
                   qq{# This Makefile.PL has been autogenerated by the module CPAN.pm
# because there was no Makefile.PL supplied.
# Autogenerated on: }.scalar localtime().qq{

use ExtUtils::MakeMaker;
WriteMakefile(
              NAME => q[$cf],$exefile_stanza
             );
});
        $fh->close;
    }
}

#-> CPAN;:Distribution::_contains_crud
sub _contains_crud {
    my($self,$dir) = @_;
    my(@dirs, $dh, @files);
    opendir $dh, $dir or return;
    my $dirent;
    for $dirent (readdir $dh) {
        next if $dirent =~ /^\.\.?$/;
        my $path = File::Spec->catdir($dir,$dirent);
        if (-d $path) {
            push @dirs, $dirent;
        } elsif (-f $path) {
            push @files, $dirent;
        }
    }
    if (@dirs && @files) {
        return "both files[@files] and directories[@dirs]";
    } elsif (@files > 2) {
        return "several files[@files] but no Makefile.PL or Build.PL";
    }
    return;
}

#-> CPAN;:Distribution::_exefile_stanza
sub _exefile_stanza {
    my($self,$build_dir,$local_file) = @_;

            my $fh = FileHandle->new;
            my $script_file = File::Spec->catfile($build_dir,$local_file);
            $fh->open($script_file)
                or Carp::croak("Could not open script '$script_file': $!");
            local $/ = "\n";
            # name parsen und prereq
            my($state) = "poddir";
            my($name, $prereq) = ("", "");
            while (<$fh>) {
                if ($state eq "poddir" && /^=head\d\s+(\S+)/) {
                    if ($1 eq 'NAME') {
                        $state = "name";
                    } elsif ($1 eq 'PREREQUISITES') {
                        $state = "prereq";
                    }
                } elsif ($state =~ m{^(name|prereq)$}) {
                    if (/^=/) {
                        $state = "poddir";
                    } elsif (/^\s*$/) {
                        # nop
                    } elsif ($state eq "name") {
                        if ($name eq "") {
                            ($name) = /^(\S+)/;
                            $state = "poddir";
                        }
                    } elsif ($state eq "prereq") {
                        $prereq .= $_;
                    }
                } elsif (/^=cut\b/) {
                    last;
                }
            }
            $fh->close;

            for ($name) {
                s{.*<}{};       # strip X<...>
                s{>.*}{};
            }
            chomp $prereq;
            $prereq = join " ", split /\s+/, $prereq;
            my($PREREQ_PM) = join("\n", map {
                s{.*<}{};       # strip X<...>
                s{>.*}{};
                if (/[\s\'\"]/) { # prose?
                } else {
                    s/[^\w:]$//; # period?
                    " "x28 . "'$_' => 0,";
                }
            } split /\s*,\s*/, $prereq);

            if ($name) {
                my $to_file = File::Spec->catfile($build_dir, $name);
                rename $script_file, $to_file
                    or die "Can't rename $script_file to $to_file: $!";
            }

    return "
              EXE_FILES => ['$name'],
              PREREQ_PM => {
$PREREQ_PM
                           },
";
}

#-> CPAN::Distribution::_signature_business
sub _signature_business {
    my($self) = @_;
    my $check_sigs = CPAN::HandleConfig->prefs_lookup($self,
                                                      q{check_sigs});
    if ($check_sigs) {
        if ($CPAN::META->has_inst("Module::Signature")) {
            if (-f "SIGNATURE") {
                $self->debug("Module::Signature is installed, verifying") if $CPAN::DEBUG;
                my $rv = Module::Signature::verify();
                if ($rv != Module::Signature::SIGNATURE_OK() and
                    $rv != Module::Signature::SIGNATURE_MISSING()) {
                    $CPAN::Frontend->mywarn(
                                            qq{\nSignature invalid for }.
                                            qq{distribution file. }.
                                            qq{Please investigate.\n\n}
                                           );

                    my $wrap =
                        sprintf(qq{I'd recommend removing %s. Some error occurred   }.
                                qq{while checking its signature, so it could        }.
                                qq{be invalid. Maybe you have configured            }.
                                qq{your 'urllist' with a bad URL. Please check this }.
                                qq{array with 'o conf urllist' and retry. Or        }.
                                qq{examine the distribution in a subshell. Try
  look %s
and run
  cpansign -v
},
                                $self->{localfile},
                                $self->pretty_id,
                               );
                    $self->{signature_verify} = CPAN::Distrostatus->new("NO");
                    $CPAN::Frontend->mywarn(Text::Wrap::wrap("","",$wrap));
                    $CPAN::Frontend->mysleep(5) if $CPAN::Frontend->can("mysleep");
                } else {
                    $self->{signature_verify} = CPAN::Distrostatus->new("YES");
                    $self->debug("Module::Signature has verified") if $CPAN::DEBUG;
                }
            } else {
                $CPAN::Frontend->mywarn(qq{Package came without SIGNATURE\n\n});
            }
        } else {
            $self->debug("Module::Signature is NOT installed") if $CPAN::DEBUG;
        }
    }
}

#-> CPAN::Distribution::untar_me ;
sub untar_me {
    my($self,$ct) = @_;
    $self->{archived} = "tar";
    my $result = eval { $ct->untar() };
    if ($result) {
        $self->{unwrapped} = CPAN::Distrostatus->new("YES");
    } else {
        $self->{unwrapped} = CPAN::Distrostatus->new("NO -- untar failed");
    }
}

# CPAN::Distribution::unzip_me ;
sub unzip_me {
    my($self,$ct) = @_;
    $self->{archived} = "zip";
    if ($ct->unzip()) {
        $self->{unwrapped} = CPAN::Distrostatus->new("YES");
    } else {
        $self->{unwrapped} = CPAN::Distrostatus->new("NO -- unzip failed");
    }
    return;
}

sub handle_singlefile {
    my($self,$local_file) = @_;

    if ( $local_file =~ /\.pm(\.(gz|Z))?(?!\n)\Z/ ) {
        $self->{archived} = "pm";
    } elsif ( $local_file =~ /\.patch(\.(gz|bz2))?(?!\n)\Z/ ) {
        $self->{archived} = "patch";
    } else {
        $self->{archived} = "maybe_pl";
    }

    my $to = File::Basename::basename($local_file);
    if ($to =~ s/\.(gz|Z)(?!\n)\Z//) {
        if (eval{CPAN::Tarzip->new($local_file)->gunzip($to)}) {
            $self->{unwrapped} = CPAN::Distrostatus->new("YES");
        } else {
            $self->{unwrapped} = CPAN::Distrostatus->new("NO -- uncompressing failed");
        }
    } else {
        if (File::Copy::cp($local_file,".")) {
            $self->{unwrapped} = CPAN::Distrostatus->new("YES");
        } else {
            $self->{unwrapped} = CPAN::Distrostatus->new("NO -- copying failed");
        }
    }
    return $to;
}

#-> sub CPAN::Distribution::new ;
sub new {
    my($class,%att) = @_;

    # $CPAN::META->{cachemgr} ||= CPAN::CacheMgr->new();

    my $this = { %att };
    return bless $this, $class;
}

#-> sub CPAN::Distribution::look ;
sub look {
    my($self) = @_;

    if ($^O eq 'MacOS') {
      $self->Mac::BuildTools::look;
      return;
    }

    if (  $CPAN::Config->{'shell'} ) {
        $CPAN::Frontend->myprint(qq{
Trying to open a subshell in the build directory...
});
    } else {
        $CPAN::Frontend->myprint(qq{
Your configuration does not define a value for subshells.
Please define it with "o conf shell <your shell>"
});
        return;
    }
    my $dist = $self->id;
    my $dir;
    unless ($dir = $self->dir) {
        $self->get;
    }
    unless ($dir ||= $self->dir) {
        $CPAN::Frontend->mywarn(qq{
Could not determine which directory to use for looking at $dist.
});
        return;
    }
    my $pwd  = CPAN::anycwd();
    $self->safe_chdir($dir);
    $CPAN::Frontend->myprint(qq{Working directory is $dir\n});
    {
        local $ENV{CPAN_SHELL_LEVEL} = $ENV{CPAN_SHELL_LEVEL}||0;
        $ENV{CPAN_SHELL_LEVEL} += 1;
        my $shell = CPAN::HandleConfig->safe_quote($CPAN::Config->{'shell'});

        local $ENV{PERL5LIB} = defined($ENV{PERL5LIB})
            ? $ENV{PERL5LIB}
                : ($ENV{PERLLIB} || "");

        local $ENV{PERL5OPT} = defined $ENV{PERL5OPT} ? $ENV{PERL5OPT} : "";
        $CPAN::META->set_perl5lib;
        local $ENV{MAKEFLAGS}; # protect us from outer make calls

        unless (system($shell) == 0) {
            my $code = $? >> 8;
            $CPAN::Frontend->mywarn("Subprocess shell exit code $code\n");
        }
    }
    $self->safe_chdir($pwd);
}

# CPAN::Distribution::cvs_import ;
sub cvs_import {
    my($self) = @_;
    $self->get;
    my $dir = $self->dir;

    my $package = $self->called_for;
    my $module = $CPAN::META->instance('CPAN::Module', $package);
    my $version = $module->cpan_version;

    my $userid = $self->cpan_userid;

    my $cvs_dir = (split /\//, $dir)[-1];
    $cvs_dir =~ s/-\d+[^-]+(?!\n)\Z//;
    my $cvs_root =
      $CPAN::Config->{cvsroot} || $ENV{CVSROOT};
    my $cvs_site_perl =
      $CPAN::Config->{cvs_site_perl} || $ENV{CVS_SITE_PERL};
    if ($cvs_site_perl) {
        $cvs_dir = "$cvs_site_perl/$cvs_dir";
    }
    my $cvs_log = qq{"imported $package $version sources"};
    $version =~ s/\./_/g;
    # XXX cvs: undocumented and unclear how it was meant to work
    my @cmd = ('cvs', '-d', $cvs_root, 'import', '-m', $cvs_log,
               "$cvs_dir", $userid, "v$version");

    my $pwd  = CPAN::anycwd();
    chdir($dir) or $CPAN::Frontend->mydie(qq{Could not chdir to "$dir": $!});

    $CPAN::Frontend->myprint(qq{Working directory is $dir\n});

    $CPAN::Frontend->myprint(qq{@cmd\n});
    system(@cmd) == 0 or
    # XXX cvs
        $CPAN::Frontend->mydie("cvs import failed");
    chdir($pwd) or $CPAN::Frontend->mydie(qq{Could not chdir to "$pwd": $!});
}

#-> sub CPAN::Distribution::readme ;
sub readme {
    my($self) = @_;
    my($dist) = $self->id;
    my($sans,$suffix) = $dist =~ /(.+)\.(tgz|tar[\._-]gz|tar\.Z|zip)$/;
    $self->debug("sans[$sans] suffix[$suffix]\n") if $CPAN::DEBUG;
    my($local_file);
    my($local_wanted) =
        File::Spec->catfile(
                            $CPAN::Config->{keep_source_where},
                            "authors",
                            "id",
                            split(/\//,"$sans.readme"),
                           );
    $self->debug("Doing localize") if $CPAN::DEBUG;
    $local_file = CPAN::FTP->localize("authors/id/$sans.readme",
                                      $local_wanted)
        or $CPAN::Frontend->mydie(qq{No $sans.readme found});;

    if ($^O eq 'MacOS') {
        Mac::BuildTools::launch_file($local_file);
        return;
    }

    my $fh_pager = FileHandle->new;
    local($SIG{PIPE}) = "IGNORE";
    my $pager = $CPAN::Config->{'pager'} || "cat";
    $fh_pager->open("|$pager")
        or die "Could not open pager $pager\: $!";
    my $fh_readme = FileHandle->new;
    $fh_readme->open($local_file)
        or $CPAN::Frontend->mydie(qq{Could not open "$local_file": $!});
    $CPAN::Frontend->myprint(qq{
Displaying file
  $local_file
with pager "$pager"
});
    $fh_pager->print(<$fh_readme>);
    $fh_pager->close;
}

#-> sub CPAN::Distribution::verifyCHECKSUM ;
sub verifyCHECKSUM {
    my($self) = @_;
  EXCUSE: {
        my @e;
        $self->{CHECKSUM_STATUS} ||= "";
        $self->{CHECKSUM_STATUS} eq "OK" and push @e, "Checksum was ok";
        $CPAN::Frontend->myprint(join "", map {"  $_\n"} @e) and return if @e;
    }
    my($lc_want,$lc_file,@local,$basename);
    @local = split(/\//,$self->id);
    pop @local;
    push @local, "CHECKSUMS";
    $lc_want =
        File::Spec->catfile($CPAN::Config->{keep_source_where},
                            "authors", "id", @local);
    local($") = "/";
    if (my $size = -s $lc_want) {
        $self->debug("lc_want[$lc_want]size[$size]") if $CPAN::DEBUG;
        if ($self->CHECKSUM_check_file($lc_want,1)) {
            return $self->{CHECKSUM_STATUS} = "OK";
        }
    }
    $lc_file = CPAN::FTP->localize("authors/id/@local",
                                   $lc_want,1);
    unless ($lc_file) {
        $CPAN::Frontend->myprint("Trying $lc_want.gz\n");
        $local[-1] .= ".gz";
        $lc_file = CPAN::FTP->localize("authors/id/@local",
                                       "$lc_want.gz",1);
        if ($lc_file) {
            $lc_file =~ s/\.gz(?!\n)\Z//;
            eval{CPAN::Tarzip->new("$lc_file.gz")->gunzip($lc_file)};
        } else {
            return;
        }
    }
    if ($self->CHECKSUM_check_file($lc_file)) {
        return $self->{CHECKSUM_STATUS} = "OK";
    }
}

#-> sub CPAN::Distribution::SIG_check_file ;
sub SIG_check_file {
    my($self,$chk_file) = @_;
    my $rv = eval { Module::Signature::_verify($chk_file) };

    if ($rv == Module::Signature::SIGNATURE_OK()) {
        $CPAN::Frontend->myprint("Signature for $chk_file ok\n");
        return $self->{SIG_STATUS} = "OK";
    } else {
        $CPAN::Frontend->myprint(qq{\nSignature invalid for }.
                                 qq{distribution file. }.
                                 qq{Please investigate.\n\n}.
                                 $self->as_string,
                                 $CPAN::META->instance(
                                                       'CPAN::Author',
                                                       $self->cpan_userid
                                                      )->as_string);

        my $wrap = qq{I\'d recommend removing $chk_file. Its signature
is invalid. Maybe you have configured your 'urllist' with
a bad URL. Please check this array with 'o conf urllist', and
retry.};

        $CPAN::Frontend->mydie(Text::Wrap::wrap("","",$wrap));
    }
}

#-> sub CPAN::Distribution::CHECKSUM_check_file ;

# sloppy is 1 when we have an old checksums file that maybe is good
# enough

sub CHECKSUM_check_file {
    my($self,$chk_file,$sloppy) = @_;
    my($cksum,$file,$basename);

    $sloppy ||= 0;
    $self->debug("chk_file[$chk_file]sloppy[$sloppy]") if $CPAN::DEBUG;
    my $check_sigs = CPAN::HandleConfig->prefs_lookup($self,
                                                      q{check_sigs});
    if ($check_sigs) {
        if ($CPAN::META->has_inst("Module::Signature")) {
            $self->debug("Module::Signature is installed, verifying") if $CPAN::DEBUG;
            $self->SIG_check_file($chk_file);
        } else {
            $self->debug("Module::Signature is NOT installed") if $CPAN::DEBUG;
        }
    }

    $file = $self->{localfile};
    $basename = File::Basename::basename($file);
    my $fh = FileHandle->new;
    if (open $fh, $chk_file) {
        local($/);
        my $eval = <$fh>;
        $eval =~ s/\015?\012/\n/g;
        close $fh;
        my($compmt) = Safe->new();
        $cksum = $compmt->reval($eval);
        if ($@) {
            rename $chk_file, "$chk_file.bad";
            Carp::confess($@) if $@;
        }
    } else {
        Carp::carp "Could not open $chk_file for reading";
    }

    if (! ref $cksum or ref $cksum ne "HASH") {
        $CPAN::Frontend->mywarn(qq{
Warning: checksum file '$chk_file' broken.

When trying to read that file I expected to get a hash reference
for further processing, but got garbage instead.
});
        my $answer = CPAN::Shell::colorable_makemaker_prompt("Proceed nonetheless?", "no");
        $answer =~ /^\s*y/i or $CPAN::Frontend->mydie("Aborted.\n");
        $self->{CHECKSUM_STATUS} = "NIL -- CHECKSUMS file broken";
        return;
    } elsif (exists $cksum->{$basename}{sha256}) {
        $self->debug("Found checksum for $basename:" .
                     "$cksum->{$basename}{sha256}\n") if $CPAN::DEBUG;

        open($fh, $file);
        binmode $fh;
        my $eq = $self->eq_CHECKSUM($fh,$cksum->{$basename}{sha256});
        $fh->close;
        $fh = CPAN::Tarzip->TIEHANDLE($file);

        unless ($eq) {
            my $dg = Digest::SHA->new(256);
            my($data,$ref);
            $ref = \$data;
            while ($fh->READ($ref, 4096) > 0) {
                $dg->add($data);
            }
            my $hexdigest = $dg->hexdigest;
            $eq += $hexdigest eq $cksum->{$basename}{'sha256-ungz'};
        }

        if ($eq) {
            $CPAN::Frontend->myprint("Checksum for $file ok\n");
            return $self->{CHECKSUM_STATUS} = "OK";
        } else {
            $CPAN::Frontend->myprint(qq{\nChecksum mismatch for }.
                                     qq{distribution file. }.
                                     qq{Please investigate.\n\n}.
                                     $self->as_string,
                                     $CPAN::META->instance(
                                                           'CPAN::Author',
                                                           $self->cpan_userid
                                                          )->as_string);

            my $wrap = qq{I\'d recommend removing $file. Its
checksum is incorrect. Maybe you have configured your 'urllist' with
a bad URL. Please check this array with 'o conf urllist', and
retry.};

            $CPAN::Frontend->mydie(Text::Wrap::wrap("","",$wrap));

            # former versions just returned here but this seems a
            # serious threat that deserves a die

            # $CPAN::Frontend->myprint("\n\n");
            # sleep 3;
            # return;
        }
        # close $fh if fileno($fh);
    } else {
        return if $sloppy;
        unless ($self->{CHECKSUM_STATUS}) {
            $CPAN::Frontend->mywarn(qq{
Warning: No checksum for $basename in $chk_file.

The cause for this may be that the file is very new and the checksum
has not yet been calculated, but it may also be that something is
going awry right now.
});
            my $answer = CPAN::Shell::colorable_makemaker_prompt("Proceed?", "yes");
            $answer =~ /^\s*y/i or $CPAN::Frontend->mydie("Aborted.\n");
        }
        $self->{CHECKSUM_STATUS} = "NIL -- distro not in CHECKSUMS file";
        return;
    }
}

#-> sub CPAN::Distribution::eq_CHECKSUM ;
sub eq_CHECKSUM {
    my($self,$fh,$expect) = @_;
    if ($CPAN::META->has_inst("Digest::SHA")) {
        my $dg = Digest::SHA->new(256);
        my($data);
        while (read($fh, $data, 4096)) {
            $dg->add($data);
        }
        my $hexdigest = $dg->hexdigest;
        # warn "fh[$fh] hex[$hexdigest] aexp[$expectMD5]";
        return $hexdigest eq $expect;
    }
    return 1;
}

#-> sub CPAN::Distribution::force ;

# Both CPAN::Modules and CPAN::Distributions know if "force" is in
# effect by autoinspection, not by inspecting a global variable. One
# of the reason why this was chosen to work that way was the treatment
# of dependencies. They should not automatically inherit the force
# status. But this has the downside that ^C and die() will return to
# the prompt but will not be able to reset the force_update
# attributes. We try to correct for it currently in the read_metadata
# routine, and immediately before we check for a Signal. I hope this
# works out in one of v1.57_53ff

# "Force get forgets previous error conditions"

#-> sub CPAN::Distribution::fforce ;
sub fforce {
  my($self, $method) = @_;
  $self->force($method,1);
}

#-> sub CPAN::Distribution::force ;
sub force {
  my($self, $method,$fforce) = @_;
  my %phase_map = (
                   get => [
                           "unwrapped",
                           "build_dir",
                           "archived",
                           "localfile",
                           "CHECKSUM_STATUS",
                           "signature_verify",
                           "prefs",
                           "prefs_file",
                           "prefs_file_doc",
                          ],
                   make => [
                            "writemakefile",
                            "make",
                            "modulebuild",
                            "prereq_pm",
                            "prereq_pm_detected",
                           ],
                   test => [
                            "badtestcnt",
                            "make_test",
                           ],
                   install => [
                               "install",
                              ],
                   unknown => [
                               "reqtype",
                               "yaml_content",
                              ],
                  );
  my $methodmatch = 0;
  my $ldebug = 0;
 PHASE: for my $phase (qw(unknown get make test install)) { # order matters
      $methodmatch = 1 if $fforce || $phase eq $method;
      next unless $methodmatch;
    ATTRIBUTE: for my $att (@{$phase_map{$phase}}) {
          if ($phase eq "get") {
              if (substr($self->id,-1,1) eq "."
                  && $att =~ /(unwrapped|build_dir|archived)/ ) {
                  # cannot be undone for local distros
                  next ATTRIBUTE;
              }
              if ($att eq "build_dir"
                  && $self->{build_dir}
                  && $CPAN::META->{is_tested}
                 ) {
                  delete $CPAN::META->{is_tested}{$self->{build_dir}};
              }
          } elsif ($phase eq "test") {
              if ($att eq "make_test"
                  && $self->{make_test}
                  && $self->{make_test}{COMMANDID}
                  && $self->{make_test}{COMMANDID} == $CPAN::CurrentCommandId
                 ) {
                  # endless loop too likely
                  next ATTRIBUTE;
              }
          }
          delete $self->{$att};
          if ($ldebug || $CPAN::DEBUG) {
              # local $CPAN::DEBUG = 16; # Distribution
              CPAN->debug(sprintf "id[%s]phase[%s]att[%s]", $self->id, $phase, $att);
          }
      }
  }
  if ($method && $method =~ /make|test|install/) {
    $self->{force_update} = 1; # name should probably have been force_install
  }
}

#-> sub CPAN::Distribution::notest ;
sub notest {
  my($self, $method) = @_;
  # $CPAN::Frontend->mywarn("XDEBUG: set notest for $self $method");
  $self->{"notest"}++; # name should probably have been force_install
}

#-> sub CPAN::Distribution::unnotest ;
sub unnotest {
  my($self) = @_;
  # warn "XDEBUG: deleting notest";
  delete $self->{notest};
}

#-> sub CPAN::Distribution::unforce ;
sub unforce {
  my($self) = @_;
  delete $self->{force_update};
}

#-> sub CPAN::Distribution::isa_perl ;
sub isa_perl {
  my($self) = @_;
  my $file = File::Basename::basename($self->id);
  if ($file =~ m{ ^ perl
                  -?
                  (5)
                  ([._-])
                  (
                   \d{3}(_[0-4][0-9])?
                   |
                   \d+\.\d+
                  )
                  \.tar[._-](?:gz|bz2)
                  (?!\n)\Z
                }xs) {
    return "$1.$3";
  } elsif ($self->cpan_comment
           &&
           $self->cpan_comment =~ /isa_perl\(.+?\)/) {
    return $1;
  }
}


#-> sub CPAN::Distribution::perl ;
sub perl {
    my ($self) = @_;
    if (! $self) {
        use Carp qw(carp);
        carp __PACKAGE__ . "::perl was called without parameters.";
    }
    return CPAN::HandleConfig->safe_quote($CPAN::Perl);
}


#-> sub CPAN::Distribution::make ;
sub make {
    my($self) = @_;
    if (my $goto = $self->prefs->{goto}) {
        return $self->goto($goto);
    }
    my $make = $self->{modulebuild} ? "Build" : "make";
    # Emergency brake if they said install Pippi and get newest perl
    if ($self->isa_perl) {
        if (
            $self->called_for ne $self->id &&
            ! $self->{force_update}
        ) {
            # if we die here, we break bundles
            $CPAN::Frontend
                ->mywarn(sprintf(
                            qq{The most recent version "%s" of the module "%s"
is part of the perl-%s distribution. To install that, you need to run
  force install %s   --or--
  install %s
},
                             $CPAN::META->instance(
                                                   'CPAN::Module',
                                                   $self->called_for
                                                  )->cpan_version,
                             $self->called_for,
                             $self->isa_perl,
                             $self->called_for,
                             $self->id,
                            ));
            $self->{make} = CPAN::Distrostatus->new("NO isa perl");
            $CPAN::Frontend->mysleep(1);
            return;
        }
    }
    $CPAN::Frontend->myprint(sprintf "Running %s for %s\n", $make, $self->id);
    $self->get;
    return if $self->prefs->{disabled} && ! $self->{force_update};
    if ($self->{configure_requires_later}) {
        return;
    }
    local $ENV{PERL5LIB} = defined($ENV{PERL5LIB})
                           ? $ENV{PERL5LIB}
                           : ($ENV{PERLLIB} || "");
    local $ENV{PERL5OPT} = defined $ENV{PERL5OPT} ? $ENV{PERL5OPT} : "";
    $CPAN::META->set_perl5lib;
    local $ENV{MAKEFLAGS}; # protect us from outer make calls

    if ($CPAN::Signal) {
        delete $self->{force_update};
        return;
    }

    my $builddir;
  EXCUSE: {
        my @e;
        if (!$self->{archived} || $self->{archived} eq "NO") {
            push @e, "Is neither a tar nor a zip archive.";
        }

        if (!$self->{unwrapped}
            || (
                UNIVERSAL::can($self->{unwrapped},"failed") ?
                $self->{unwrapped}->failed :
                $self->{unwrapped} =~ /^NO/
               )) {
            push @e, "Had problems unarchiving. Please build manually";
        }

        unless ($self->{force_update}) {
            exists $self->{signature_verify} and
                (
                 UNIVERSAL::can($self->{signature_verify},"failed") ?
                 $self->{signature_verify}->failed :
                 $self->{signature_verify} =~ /^NO/
                )
                and push @e, "Did not pass the signature test.";
        }

        if (exists $self->{writemakefile} &&
            (
             UNIVERSAL::can($self->{writemakefile},"failed") ?
             $self->{writemakefile}->failed :
             $self->{writemakefile} =~ /^NO/
            )) {
            # XXX maybe a retry would be in order?
            my $err = UNIVERSAL::can($self->{writemakefile},"text") ?
                $self->{writemakefile}->text :
                    $self->{writemakefile};
            $err =~ s/^NO\s*(--\s+)?//;
            $err ||= "Had some problem writing Makefile";
            $err .= ", won't make";
            push @e, $err;
        }

        if (defined $self->{make}) {
            if (UNIVERSAL::can($self->{make},"failed") ?
                $self->{make}->failed :
                $self->{make} =~ /^NO/) {
                if ($self->{force_update}) {
                    # Trying an already failed 'make' (unless somebody else blocks)
                } else {
                    # introduced for turning recursion detection into a distrostatus
                    my $error = length $self->{make}>3
                        ? substr($self->{make},3) : "Unknown error";
                    $CPAN::Frontend->mywarn("Could not make: $error\n");
                    $self->store_persistent_state;
                    return;
                }
            } else {
                push @e, "Has already been made";
                my $wait_for_prereqs = eval { $self->satisfy_requires };
                return 1 if $wait_for_prereqs;   # tells queuerunner to continue
                return $self->goodbye($@) if $@; # tells queuerunner to stop
            }
        }

        my $later = $self->{later} || $self->{configure_requires_later};
        if ($later) { # see also undelay
            if ($later) {
                push @e, $later;
            }
        }

        $CPAN::Frontend->myprint(join "", map {"  $_\n"} @e) and return if @e;
        $builddir = $self->dir or
            $CPAN::Frontend->mydie("PANIC: Cannot determine build directory\n");
        unless (chdir $builddir) {
            push @e, "Couldn't chdir to '$builddir': $!";
        }
        $CPAN::Frontend->mywarn(join "", map {"  $_\n"} @e) and return if @e;
    }
    if ($CPAN::Signal) {
        delete $self->{force_update};
        return;
    }
    $CPAN::Frontend->myprint("\n  CPAN.pm: Going to build ".$self->id."\n\n");
    $self->debug("Changed directory to $builddir") if $CPAN::DEBUG;

    if ($^O eq 'MacOS') {
        Mac::BuildTools::make($self);
        return;
    }

    my %env;
    while (my($k,$v) = each %ENV) {
        next unless defined $v;
        $env{$k} = $v;
    }
    local %ENV = %env;
    my $system;
    my $pl_commandline;
    if ($self->prefs->{pl}) {
        $pl_commandline = $self->prefs->{pl}{commandline};
    }
    if ($pl_commandline) {
        $system = $pl_commandline;
        $ENV{PERL} = $^X;
    } elsif ($self->{'configure'}) {
        $system = $self->{'configure'};
    } elsif ($self->{modulebuild}) {
        my($perl) = $self->perl or die "Couldn\'t find executable perl\n";
        $system = "$perl Build.PL $CPAN::Config->{mbuildpl_arg}";
    } else {
        my($perl) = $self->perl or die "Couldn\'t find executable perl\n";
        my $switch = "";
# This needs a handler that can be turned on or off:
#        $switch = "-MExtUtils::MakeMaker ".
#            "-Mops=:default,:filesys_read,:filesys_open,require,chdir"
#            if $] > 5.00310;
        my $makepl_arg = $self->_make_phase_arg("pl");
        $ENV{PERL5_CPAN_IS_EXECUTING} = File::Spec->catfile($self->{build_dir},
                                                            "Makefile.PL");
        $system = sprintf("%s%s Makefile.PL%s",
                          $perl,
                          $switch ? " $switch" : "",
                          $makepl_arg ? " $makepl_arg" : "",
                         );
    }
    my $pl_env;
    if ($self->prefs->{pl}) {
        $pl_env = $self->prefs->{pl}{env};
    }
    if ($pl_env) {
        for my $e (keys %$pl_env) {
            $ENV{$e} = $pl_env->{$e};
        }
    }
    if (exists $self->{writemakefile}) {
    } else {
        local($SIG{ALRM}) = sub { die "inactivity_timeout reached\n" };
        my($ret,$pid,$output);
        $@ = "";
        my $go_via_alarm;
        if ($CPAN::Config->{inactivity_timeout}) {
            require Config;
            if ($Config::Config{d_alarm}
                &&
                $Config::Config{d_alarm} eq "define"
               ) {
                $go_via_alarm++
            } else {
                $CPAN::Frontend->mywarn("Warning: you have configured the config ".
                                        "variable 'inactivity_timeout' to ".
                                        "'$CPAN::Config->{inactivity_timeout}'. But ".
                                        "on this machine the system call 'alarm' ".
                                        "isn't available. This means that we cannot ".
                                        "provide the feature of intercepting long ".
                                        "waiting code and will turn this feature off.\n"
                                       );
                $CPAN::Config->{inactivity_timeout} = 0;
            }
        }
        if ($go_via_alarm) {
            if ( $self->_should_report('pl') ) {
                ($output, $ret) = CPAN::Reporter::record_command(
                    $system,
                    $CPAN::Config->{inactivity_timeout},
                );
                CPAN::Reporter::grade_PL( $self, $system, $output, $ret );
            }
            else {
                eval {
                    alarm $CPAN::Config->{inactivity_timeout};
                    local $SIG{CHLD}; # = sub { wait };
                    if (defined($pid = fork)) {
                        if ($pid) { #parent
                            # wait;
                            waitpid $pid, 0;
                        } else {    #child
                            # note, this exec isn't necessary if
                            # inactivity_timeout is 0. On the Mac I'd
                            # suggest, we set it always to 0.
                            exec $system;
                        }
                    } else {
                        $CPAN::Frontend->myprint("Cannot fork: $!");
                        return;
                    }
                };
                alarm 0;
                if ($@) {
                    kill 9, $pid;
                    waitpid $pid, 0;
                    my $err = "$@";
                    $CPAN::Frontend->myprint($err);
                    $self->{writemakefile} = CPAN::Distrostatus->new("NO $err");
                    $@ = "";
                    $self->store_persistent_state;
                    return $self->goodbye("$system -- TIMED OUT");
                }
            }
        } else {
            if (my $expect_model = $self->_prefs_with_expect("pl")) {
                # XXX probably want to check _should_report here and warn
                # about not being able to use CPAN::Reporter with expect
                $ret = $self->_run_via_expect($system,'writemakefile',$expect_model);
                if (! defined $ret
                    && $self->{writemakefile}
                    && $self->{writemakefile}->failed) {
                    # timeout
                    return;
                }
            }
            elsif ( $self->_should_report('pl') ) {
                ($output, $ret) = CPAN::Reporter::record_command($system);
                CPAN::Reporter::grade_PL( $self, $system, $output, $ret );
            }
            else {
                $ret = system($system);
            }
            if ($ret != 0) {
                $self->{writemakefile} = CPAN::Distrostatus
                    ->new("NO '$system' returned status $ret");
                $CPAN::Frontend->mywarn("Warning: No success on command[$system]\n");
                $self->store_persistent_state;
                return $self->goodbye("$system -- NOT OK");
            }
        }
        if (-f "Makefile" || -f "Build") {
            $self->{writemakefile} = CPAN::Distrostatus->new("YES");
            delete $self->{make_clean}; # if cleaned before, enable next
        } else {
            my $makefile = $self->{modulebuild} ? "Build" : "Makefile";
            my $why = "No '$makefile' created";
            $CPAN::Frontend->mywarn($why);
            $self->{writemakefile} = CPAN::Distrostatus
                ->new(qq{NO -- $why\n});
            $self->store_persistent_state;
            return $self->goodbye("$system -- NOT OK");
        }
    }
    if ($CPAN::Signal) {
        delete $self->{force_update};
        return;
    }
    my $wait_for_prereqs = eval { $self->satisfy_requires };
    return 1 if $wait_for_prereqs;   # tells queuerunner to continue
    return $self->goodbye($@) if $@; # tells queuerunner to stop
    if ($CPAN::Signal) {
        delete $self->{force_update};
        return;
    }
    my $make_commandline;
    if ($self->prefs->{make}) {
        $make_commandline = $self->prefs->{make}{commandline};
    }
    if ($make_commandline) {
        $system = $make_commandline;
        $ENV{PERL} = CPAN::find_perl;
    } else {
        if ($self->{modulebuild}) {
            unless (-f "Build") {
                my $cwd = CPAN::anycwd();
                $CPAN::Frontend->mywarn("Alert: no Build file available for 'make $self->{id}'".
                                        " in cwd[$cwd]. Danger, Will Robinson!\n");
                $CPAN::Frontend->mysleep(5);
            }
            $system = join " ", $self->_build_command(), $CPAN::Config->{mbuild_arg};
        } else {
            $system = join " ", $self->_make_command(),  $CPAN::Config->{make_arg};
        }
        $system =~ s/\s+$//;
        my $make_arg = $self->_make_phase_arg("make");
        $system = sprintf("%s%s",
                          $system,
                          $make_arg ? " $make_arg" : "",
                         );
    }
    my $make_env;
    if ($self->prefs->{make}) {
        $make_env = $self->prefs->{make}{env};
    }
    if ($make_env) { # overriding the local ENV of PL, not the outer
                     # ENV, but unlikely to be a risk
        for my $e (keys %$make_env) {
            $ENV{$e} = $make_env->{$e};
        }
    }
    my $expect_model = $self->_prefs_with_expect("make");
    my $want_expect = 0;
    if ( $expect_model && @{$expect_model->{talk}} ) {
        my $can_expect = $CPAN::META->has_inst("Expect");
        if ($can_expect) {
            $want_expect = 1;
        } else {
            $CPAN::Frontend->mywarn("Expect not installed, falling back to ".
                                    "system()\n");
        }
    }
    my $system_ok;
    if ($want_expect) {
        # XXX probably want to check _should_report here and
        # warn about not being able to use CPAN::Reporter with expect
        $system_ok = $self->_run_via_expect($system,'make',$expect_model) == 0;
    }
    elsif ( $self->_should_report('make') ) {
        my ($output, $ret) = CPAN::Reporter::record_command($system);
        CPAN::Reporter::grade_make( $self, $system, $output, $ret );
        $system_ok = ! $ret;
    }
    else {
        $system_ok = system($system) == 0;
    }
    $self->introduce_myself;
    if ( $system_ok ) {
        $CPAN::Frontend->myprint("  $system -- OK\n");
        $self->{make} = CPAN::Distrostatus->new("YES");
    } else {
        $self->{writemakefile} ||= CPAN::Distrostatus->new("YES");
        $self->{make} = CPAN::Distrostatus->new("NO");
        $CPAN::Frontend->mywarn("  $system -- NOT OK\n");
    }
    $self->store_persistent_state;
}

# CPAN::Distribution::goodbye ;
sub goodbye {
    my($self,$goodbye) = @_;
    my $id = $self->pretty_id;
    $CPAN::Frontend->mywarn("  $id\n  $goodbye\n");
    return;
}

# CPAN::Distribution::_run_via_expect ;
sub _run_via_expect {
    my($self,$system,$phase,$expect_model) = @_;
    CPAN->debug("system[$system]expect_model[$expect_model]") if $CPAN::DEBUG;
    if ($CPAN::META->has_inst("Expect")) {
        my $expo = Expect->new;  # expo Expect object;
        $expo->spawn($system);
        $expect_model->{mode} ||= "deterministic";
        if ($expect_model->{mode} eq "deterministic") {
            return $self->_run_via_expect_deterministic($expo,$phase,$expect_model);
        } elsif ($expect_model->{mode} eq "anyorder") {
            return $self->_run_via_expect_anyorder($expo,$phase,$expect_model);
        } else {
            die "Panic: Illegal expect mode: $expect_model->{mode}";
        }
    } else {
        $CPAN::Frontend->mywarn("Expect not installed, falling back to system()\n");
        return system($system);
    }
}

sub _run_via_expect_anyorder {
    my($self,$expo,$phase,$expect_model) = @_;
    my $timeout = $expect_model->{timeout} || 5;
    my $reuse = $expect_model->{reuse};
    my @expectacopy = @{$expect_model->{talk}}; # we trash it!
    my $but = "";
    my $timeout_start = time;
  EXPECT: while () {
        my($eof,$ran_into_timeout);
        # XXX not up to the full power of expect. one could certainly
        # wrap all of the talk pairs into a single expect call and on
        # success tweak it and step ahead to the next question. The
        # current implementation unnecessarily limits itself to a
        # single match.
        my @match = $expo->expect(1,
                                  [ eof => sub {
                                        $eof++;
                                    } ],
                                  [ timeout => sub {
                                        $ran_into_timeout++;
                                    } ],
                                  -re => eval"qr{.}",
                                 );
        if ($match[2]) {
            $but .= $match[2];
        }
        $but .= $expo->clear_accum;
        if ($eof) {
            $expo->soft_close;
            return $expo->exitstatus();
        } elsif ($ran_into_timeout) {
            # warn "DEBUG: they are asking a question, but[$but]";
            for (my $i = 0; $i <= $#expectacopy; $i+=2) {
                my($next,$send) = @expectacopy[$i,$i+1];
                my $regex = eval "qr{$next}";
                # warn "DEBUG: will compare with regex[$regex].";
                if ($but =~ /$regex/) {
                    # warn "DEBUG: will send send[$send]";
                    $expo->send($send);
                    # never allow reusing an QA pair unless they told us
                    splice @expectacopy, $i, 2 unless $reuse;
                    next EXPECT;
                }
            }
            my $have_waited = time - $timeout_start;
            if ($have_waited < $timeout) {
                # warn "DEBUG: have_waited[$have_waited]timeout[$timeout]";
                next EXPECT;
            }
            my $why = "could not answer a question during the dialog";
            $CPAN::Frontend->mywarn("Failing: $why\n");
            $self->{$phase} =
                CPAN::Distrostatus->new("NO $why");
            return 0;
        }
    }
}

sub _run_via_expect_deterministic {
    my($self,$expo,$phase,$expect_model) = @_;
    my $ran_into_timeout;
    my $ran_into_eof;
    my $timeout = $expect_model->{timeout} || 15; # currently unsettable
    my $expecta = $expect_model->{talk};
  EXPECT: for (my $i = 0; $i <= $#$expecta; $i+=2) {
        my($re,$send) = @$expecta[$i,$i+1];
        CPAN->debug("timeout[$timeout]re[$re]") if $CPAN::DEBUG;
        my $regex = eval "qr{$re}";
        $expo->expect($timeout,
                      [ eof => sub {
                            my $but = $expo->clear_accum;
                            $CPAN::Frontend->mywarn("EOF (maybe harmless)
expected[$regex]\nbut[$but]\n\n");
                            $ran_into_eof++;
                        } ],
                      [ timeout => sub {
                            my $but = $expo->clear_accum;
                            $CPAN::Frontend->mywarn("TIMEOUT
expected[$regex]\nbut[$but]\n\n");
                            $ran_into_timeout++;
                        } ],
                      -re => $regex);
        if ($ran_into_timeout) {
            # note that the caller expects 0 for success
            $self->{$phase} =
                CPAN::Distrostatus->new("NO timeout during expect dialog");
            return 0;
        } elsif ($ran_into_eof) {
            last EXPECT;
        }
        $expo->send($send);
    }
    $expo->soft_close;
    return $expo->exitstatus();
}

#-> CPAN::Distribution::_validate_distropref
sub _validate_distropref {
    my($self,@args) = @_;
    if (
        $CPAN::META->has_inst("CPAN::Kwalify")
        &&
        $CPAN::META->has_inst("Kwalify")
       ) {
        eval {CPAN::Kwalify::_validate("distroprefs",@args);};
        if ($@) {
            $CPAN::Frontend->mywarn($@);
        }
    } else {
        CPAN->debug("not validating '@args'") if $CPAN::DEBUG;
    }
}

#-> CPAN::Distribution::_find_prefs
sub _find_prefs {
    my($self) = @_;
    my $distroid = $self->pretty_id;
    #CPAN->debug("distroid[$distroid]") if $CPAN::DEBUG;
    my $prefs_dir = $CPAN::Config->{prefs_dir};
    return if $prefs_dir =~ /^\s*$/;
    eval { File::Path::mkpath($prefs_dir); };
    if ($@) {
        $CPAN::Frontend->mydie("Cannot create directory $prefs_dir");
    }
    my $yaml_module = CPAN::_yaml_module;
    my $ext_map = {};
    my @extensions;
    if ($CPAN::META->has_inst($yaml_module)) {
        $ext_map->{yml} = 'CPAN';
    } else {
        my @fallbacks;
        if ($CPAN::META->has_inst("Data::Dumper")) {
            push @fallbacks, $ext_map->{dd} = 'Data::Dumper';
        }
        if ($CPAN::META->has_inst("Storable")) {
            push @fallbacks, $ext_map->{st} = 'Storable';
        }
        if (@fallbacks) {
            local $" = " and ";
            unless ($self->{have_complained_about_missing_yaml}++) {
                $CPAN::Frontend->mywarn("'$yaml_module' not installed, falling back ".
                                        "to @fallbacks to read prefs '$prefs_dir'\n");
            }
        } else {
            unless ($self->{have_complained_about_missing_yaml}++) {
                $CPAN::Frontend->mywarn("'$yaml_module' not installed, cannot ".
                                        "read prefs '$prefs_dir'\n");
            }
        }
    }
    my $finder = CPAN::Distroprefs->find($prefs_dir, $ext_map);
    DIRENT: while (my $result = $finder->next) {
        if ($result->is_warning) {
            $CPAN::Frontend->mywarn($result->as_string);
            $CPAN::Frontend->mysleep(1);
            next DIRENT;
        } elsif ($result->is_fatal) {
            $CPAN::Frontend->mydie($result->as_string);
        }

        my @prefs = @{ $result->prefs };

      ELEMENT: for my $y (0..$#prefs) {
            my $pref = $prefs[$y];
            $self->_validate_distropref($pref->data, $result->abs, $y);

            # I don't know why we silently skip when there's no match, but
            # complain if there's an empty match hashref, and there's no
            # comment explaining why -- hdp, 2008-03-18
            unless ($pref->has_any_match) {
                next ELEMENT;
            }

            unless ($pref->has_valid_subkeys) {
                $CPAN::Frontend->mydie(sprintf
                    "Nonconforming .%s file '%s': " .
                    "missing match/* subattribute. " .
                    "Please remove, cannot continue.",
                    $result->ext, $result->abs,
                );
            }

            my $arg = {
                env          => \%ENV,
                distribution => $distroid,
                perl         => \&CPAN::find_perl,
                perlconfig   => \%Config::Config,
                module       => sub { [ $self->containsmods ] },
            };

            if ($pref->matches($arg)) {
                return {
                    prefs => $pref->data,
                    prefs_file => $result->abs,
                    prefs_file_doc => $y,
                };
            }

        }
    }
    return;
}

# CPAN::Distribution::prefs
sub prefs {
    my($self) = @_;
    if (exists $self->{negative_prefs_cache}
        &&
        $self->{negative_prefs_cache} != $CPAN::CurrentCommandId
       ) {
        delete $self->{negative_prefs_cache};
        delete $self->{prefs};
    }
    if (exists $self->{prefs}) {
        return $self->{prefs}; # XXX comment out during debugging
    }
    if ($CPAN::Config->{prefs_dir}) {
        CPAN->debug("prefs_dir[$CPAN::Config->{prefs_dir}]") if $CPAN::DEBUG;
        my $prefs = $self->_find_prefs();
        $prefs ||= ""; # avoid warning next line
        CPAN->debug("prefs[$prefs]") if $CPAN::DEBUG;
        if ($prefs) {
            for my $x (qw(prefs prefs_file prefs_file_doc)) {
                $self->{$x} = $prefs->{$x};
            }
            my $bs = sprintf(
                             "%s[%s]",
                             File::Basename::basename($self->{prefs_file}),
                             $self->{prefs_file_doc},
                            );
            my $filler1 = "_" x 22;
            my $filler2 = int(66 - length($bs))/2;
            $filler2 = 0 if $filler2 < 0;
            $filler2 = " " x $filler2;
            $CPAN::Frontend->myprint("
$filler1 D i s t r o P r e f s $filler1
$filler2 $bs $filler2
");
            $CPAN::Frontend->mysleep(1);
            return $self->{prefs};
        }
    }
    $self->{negative_prefs_cache} = $CPAN::CurrentCommandId;
    return $self->{prefs} = +{};
}

# CPAN::Distribution::_make_phase_arg
sub _make_phase_arg {
    my($self, $phase) = @_;
    my $_make_phase_arg;
    my $prefs = $self->prefs;
    if (
        $prefs
        && exists $prefs->{$phase}
        && exists $prefs->{$phase}{args}
        && $prefs->{$phase}{args}
       ) {
        $_make_phase_arg = join(" ",
                           map {CPAN::HandleConfig
                                 ->safe_quote($_)} @{$prefs->{$phase}{args}},
                          );
    }

# cpan[2]> o conf make[TAB]
# make                       make_install_make_command
# make_arg                   makepl_arg
# make_install_arg
# cpan[2]> o conf mbuild[TAB]
# mbuild_arg                    mbuild_install_build_command
# mbuild_install_arg            mbuildpl_arg

    my $mantra; # must switch make/mbuild here
    if ($self->{modulebuild}) {
        $mantra = "mbuild";
    } else {
        $mantra = "make";
    }
    my %map = (
               pl => "pl_arg",
               make => "_arg",
               test => "_test_arg", # does not really exist but maybe
                                    # will some day and now protects
                                    # us from unini warnings
               install => "_install_arg",
              );
    my $phase_underscore_meshup = $map{$phase};
    my $what = sprintf "%s%s", $mantra, $phase_underscore_meshup;

    $_make_phase_arg ||= $CPAN::Config->{$what};
    return $_make_phase_arg;
}

# CPAN::Distribution::_make_command
sub _make_command {
    my ($self) = @_;
    if ($self) {
        return
            CPAN::HandleConfig
                ->safe_quote(
                             CPAN::HandleConfig->prefs_lookup($self,
                                                              q{make})
                             || $Config::Config{make}
                             || 'make'
                            );
    } else {
        # Old style call, without object. Deprecated
        Carp::confess("CPAN::_make_command() used as function. Don't Do That.");
        return
          safe_quote(undef,
                     CPAN::HandleConfig->prefs_lookup($self,q{make})
                     || $CPAN::Config->{make}
                     || $Config::Config{make}
                     || 'make');
    }
}

#-> sub CPAN::Distribution::follow_prereqs ;
sub follow_prereqs {
    my($self) = shift;
    my($slot) = shift;
    my(@prereq_tuples) = grep {$_->[0] ne "perl"} @_;
    return unless @prereq_tuples;
    my(@good_prereq_tuples);
    for my $p (@prereq_tuples) {
        # XXX watch out for foul ones
        push @good_prereq_tuples, $p;
    }
    my $pretty_id = $self->pretty_id;
    my %map = (
               b => "build_requires",
               r => "requires",
               c => "commandline",
              );
    my($filler1,$filler2,$filler3,$filler4);
    my $unsat = "Unsatisfied dependencies detected during";
    my $w = length($unsat) > length($pretty_id) ? length($unsat) : length($pretty_id);
    {
        my $r = int(($w - length($unsat))/2);
        my $l = $w - length($unsat) - $r;
        $filler1 = "-"x4 . " "x$l;
        $filler2 = " "x$r . "-"x4 . "\n";
    }
    {
        my $r = int(($w - length($pretty_id))/2);
        my $l = $w - length($pretty_id) - $r;
        $filler3 = "-"x4 . " "x$l;
        $filler4 = " "x$r . "-"x4 . "\n";
    }
    $CPAN::Frontend->
        myprint("$filler1 $unsat $filler2".
                "$filler3 $pretty_id $filler4".
                join("", map {"    $_->[0] \[$map{$_->[1]}]\n"} @good_prereq_tuples),
               );
    my $follow = 0;
    if ($CPAN::Config->{prerequisites_policy} eq "follow") {
        $follow = 1;
    } elsif ($CPAN::Config->{prerequisites_policy} eq "ask") {
        my $answer = CPAN::Shell::colorable_makemaker_prompt(
"Shall I follow them and prepend them to the queue
of modules we are processing right now?", "yes");
        $follow = $answer =~ /^\s*y/i;
    } else {
        my @prereq = map { $_=>[0] } @good_prereq_tuples;
        local($") = ", ";
        $CPAN::Frontend->
            myprint("  Ignoring dependencies on modules @prereq\n");
    }
    if ($follow) {
        my $id = $self->id;
        # color them as dirty
        for my $gp (@good_prereq_tuples) {
            # warn "calling color_cmd_tmps(0,1)";
            my $p = $gp->[0];
            my $any = CPAN::Shell->expandany($p);
            $self->{$slot . "_for"}{$any->id}++;
            if ($any) {
                $any->color_cmd_tmps(0,2);
            } else {
                $CPAN::Frontend->mywarn("Warning (maybe a bug): Cannot expand prereq '$p'\n");
                $CPAN::Frontend->mysleep(2);
            }
        }
        # queue them and re-queue yourself
        CPAN::Queue->jumpqueue({qmod => $id, reqtype => $self->{reqtype}},
                               map {+{qmod=>$_->[0],reqtype=>$_->[1]}} reverse @good_prereq_tuples);
        $self->{$slot} = "Delayed until after prerequisites";
        return 1; # signal success to the queuerunner
    }
    return;
}

sub _feature_depends {
    my($self) = @_;
    my $meta_yml = $self->parse_meta_yml();
    my $optf = $meta_yml->{optional_features} or return;
    if (!ref $optf or ref $optf ne "HASH"){
        $CPAN::Frontend->mywarn("The content of optional_features is not a HASH reference. Cannot use it.\n");
        $optf = {};
    }
    my $wantf = $self->prefs->{features} or return;
    if (!ref $wantf or ref $wantf ne "ARRAY"){
        $CPAN::Frontend->mywarn("The content of 'features' is not an ARRAY reference. Cannot use it.\n");
        $wantf = [];
    }
    my $dep = +{};
    for my $wf (@$wantf) {
        if (my $f = $optf->{$wf}) {
            $CPAN::Frontend->myprint("Found the demanded feature '$wf' that ".
                                     "is accompanied by this description:\n".
                                     $f->{description}.
                                     "\n\n"
                                    );
            # configure_requires currently not in the spec, unlikely to be useful anyway
            for my $reqtype (qw(configure_requires build_requires requires)) {
                my $reqhash = $f->{$reqtype} or next;
                while (my($k,$v) = each %$reqhash) {
                    $dep->{$reqtype}{$k} = $v;
                }
            }
        } else {
            $CPAN::Frontend->mywarn("The demanded feature '$wf' was not ".
                                    "found in the META.yml file".
                                    "\n\n"
                                   );
        }
    }
    $dep;
}

#-> sub CPAN::Distribution::unsat_prereq ;
# return ([Foo,"r"],[Bar,"b"]) for normal modules
# return ([perl=>5.008]) if we need a newer perl than we are running under
# (sorry for the inconsistency, it was an accident)
sub unsat_prereq {
    my($self,$slot) = @_;
    my(%merged,$prereq_pm);
    my $prefs_depends = $self->prefs->{depends}||{};
    my $feature_depends = $self->_feature_depends();
    if ($slot eq "configure_requires_later") {
        my $meta_yml = $self->parse_meta_yml();
        if (defined $meta_yml && (! ref $meta_yml || ref $meta_yml ne "HASH")) {
            $CPAN::Frontend->mywarn("The content of META.yml is defined but not a HASH reference. Cannot use it.\n");
            $meta_yml = +{};
        }
        %merged = (
                   %{$meta_yml->{configure_requires}||{}},
                   %{$prefs_depends->{configure_requires}||{}},
                   %{$feature_depends->{configure_requires}||{}},
                  );
        $prereq_pm = {}; # configure_requires defined as "b"
    } elsif ($slot eq "later") {
        my $prereq_pm_0 = $self->prereq_pm || {};
        for my $reqtype (qw(requires build_requires)) {
            $prereq_pm->{$reqtype} = {%{$prereq_pm_0->{$reqtype}||{}}}; # copy to not pollute it
            for my $dep ($prefs_depends,$feature_depends) {
                for my $k (keys %{$dep->{$reqtype}||{}}) {
                    $prereq_pm->{$reqtype}{$k} = $dep->{$reqtype}{$k};
                }
            }
        }
        %merged = (%{$prereq_pm->{requires}||{}},%{$prereq_pm->{build_requires}||{}});
    } else {
        die "Panic: illegal slot '$slot'";
    }
    my(@need);
    my @merged = %merged;
    CPAN->debug("all merged_prereqs[@merged]") if $CPAN::DEBUG;
  NEED: while (my($need_module, $need_version) = each %merged) {
        my($available_version,$available_file,$nmo);
        if ($need_module eq "perl") {
            $available_version = $];
            $available_file = CPAN::find_perl;
        } else {
            $nmo = $CPAN::META->instance("CPAN::Module",$need_module);
            next if $nmo->uptodate;
            $available_file = $nmo->available_file;

            # if they have not specified a version, we accept any installed one
            if (defined $available_file
                and ( # a few quick shortcurcuits
                     not defined $need_version
                     or $need_version eq '0'    # "==" would trigger warning when not numeric
                     or $need_version eq "undef"
                    )) {
                next NEED;
            }

            $available_version = $nmo->available_version;
        }

        # We only want to install prereqs if either they're not installed
        # or if the installed version is too old. We cannot omit this
        # check, because if 'force' is in effect, nobody else will check.
        if (defined $available_file) {
            my $fulfills_all_version_rqs = $self->_fulfills_all_version_rqs
                ($need_module,$available_file,$available_version,$need_version);
            next NEED if $fulfills_all_version_rqs;
        }

        if ($need_module eq "perl") {
            return ["perl", $need_version];
        }
        $self->{sponsored_mods}{$need_module} ||= 0;
        CPAN->debug("need_module[$need_module]s/s/n[$self->{sponsored_mods}{$need_module}]") if $CPAN::DEBUG;
        if (my $sponsoring = $self->{sponsored_mods}{$need_module}++) {
            # We have already sponsored it and for some reason it's still
            # not available. So we do ... what??

            # if we push it again, we have a potential infinite loop

            # The following "next" was a very problematic construct.
            # It helped a lot but broke some day and had to be
            # replaced.

            # We must be able to deal with modules that come again and
            # again as a prereq and have themselves prereqs and the
            # queue becomes long but finally we would find the correct
            # order. The RecursiveDependency check should trigger a
            # die when it's becoming too weird. Unfortunately removing
            # this next breaks many other things.

            # The bug that brought this up is described in Todo under
            # "5.8.9 cannot install Compress::Zlib"

            # next; # this is the next that had to go away

            # The following "next NEED" are fine and the error message
            # explains well what is going on. For example when the DBI
            # fails and consequently DBD::SQLite fails and now we are
            # processing CPAN::SQLite. Then we must have a "next" for
            # DBD::SQLite. How can we get it and how can we identify
            # all other cases we must identify?

            my $do = $nmo->distribution;
            next NEED unless $do; # not on CPAN
            if (CPAN::Version->vcmp($need_version, $nmo->ro->{CPAN_VERSION}) > 0){
                $CPAN::Frontend->mywarn("Warning: Prerequisite ".
                                        "'$need_module => $need_version' ".
                                        "for '$self->{ID}' seems ".
                                        "not available according to the indices\n"
                                       );
                next NEED;
            }
          NOSAYER: for my $nosayer (
                                    "unwrapped",
                                    "writemakefile",
                                    "signature_verify",
                                    "make",
                                    "make_test",
                                    "install",
                                    "make_clean",
                                   ) {
                if ($do->{$nosayer}) {
                    my $selfid = $self->pretty_id;
                    my $did = $do->pretty_id;
                    if (UNIVERSAL::can($do->{$nosayer},"failed") ?
                        $do->{$nosayer}->failed :
                        $do->{$nosayer} =~ /^NO/) {
                        if ($nosayer eq "make_test"
                            &&
                            $do->{make_test}{COMMANDID} != $CPAN::CurrentCommandId
                           ) {
                            next NOSAYER;
                        }
                        $CPAN::Frontend->mywarn("Warning: Prerequisite ".
                                                "'$need_module => $need_version' ".
                                                "for '$selfid' failed when ".
                                                "processing '$did' with ".
                                                "'$nosayer => $do->{$nosayer}'. Continuing, ".
                                                "but chances to succeed are limited.\n"
                                               );
                        $CPAN::Frontend->mysleep($sponsoring/10);
                        next NEED;
                    } else { # the other guy succeeded
                        if ($nosayer =~ /^(install|make_test)$/) {
                            # we had this with
                            # DMAKI/DateTime-Calendar-Chinese-0.05.tar.gz
                            # in 2007-03 for 'make install'
                            # and 2008-04: #30464 (for 'make test')
                            $CPAN::Frontend->mywarn("Warning: Prerequisite ".
                                                    "'$need_module => $need_version' ".
                                                    "for '$selfid' already built ".
                                                    "but the result looks suspicious. ".
                                                    "Skipping another build attempt, ".
                                                    "to prevent looping endlessly.\n"
                                                   );
                            next NEED;
                        }
                    }
                }
            }
        }
        my $needed_as = exists $prereq_pm->{requires}{$need_module} ? "r" : "b";
        push @need, [$need_module,$needed_as];
    }
    my @unfolded = map { "[".join(",",@$_)."]" } @need;
    CPAN->debug("returning from unsat_prereq[@unfolded]") if $CPAN::DEBUG;
    @need;
}

sub _fulfills_all_version_rqs {
    my($self,$need_module,$available_file,$available_version,$need_version) = @_;
    my(@all_requirements) = split /\s*,\s*/, $need_version;
    local($^W) = 0;
    my $ok = 0;
  RQ: for my $rq (@all_requirements) {
        if ($rq =~ s|>=\s*||) {
        } elsif ($rq =~ s|>\s*||) {
            # 2005-12: one user
            if (CPAN::Version->vgt($available_version,$rq)) {
                $ok++;
            }
            next RQ;
        } elsif ($rq =~ s|!=\s*||) {
            # 2005-12: no user
            if (CPAN::Version->vcmp($available_version,$rq)) {
                $ok++;
                next RQ;
            } else {
                last RQ;
            }
        } elsif ($rq =~ m|<=?\s*|) {
            # 2005-12: no user
            $CPAN::Frontend->mywarn("Downgrading not supported (rq[$rq])\n");
            $ok++;
            next RQ;
        }
        if (! CPAN::Version->vgt($rq, $available_version)) {
            $ok++;
        }
        CPAN->debug(sprintf("need_module[%s]available_file[%s]".
                            "available_version[%s]rq[%s]ok[%d]",
                            $need_module,
                            $available_file,
                            $available_version,
                            CPAN::Version->readable($rq),
                            $ok,
                           )) if $CPAN::DEBUG;
    }
    return $ok == @all_requirements;
}

#-> sub CPAN::Distribution::read_yaml ;
sub read_yaml {
    my($self) = @_;
    return $self->{yaml_content} if exists $self->{yaml_content};
    my $build_dir;
    unless ($build_dir = $self->{build_dir}) {
        # maybe permission on build_dir was missing
        $CPAN::Frontend->mywarn("Warning: cannot determine META.yml without a build_dir.\n");
        return;
    }
    my $yaml = File::Spec->catfile($build_dir,"META.yml");
    $self->debug("yaml[$yaml]") if $CPAN::DEBUG;
    return unless -f $yaml;
    eval { $self->{yaml_content} = CPAN->_yaml_loadfile($yaml)->[0]; };
    if ($@) {
        $CPAN::Frontend->mywarn("Could not read ".
                                "'$yaml'. Falling back to other ".
                                "methods to determine prerequisites\n");
        return $self->{yaml_content} = undef; # if we die, then we
                                              # cannot read YAML's own
                                              # META.yml
    }
    # not "authoritative"
    for ($self->{yaml_content}) {
        if (defined $_ && (! ref $_ || ref $_ ne "HASH")) {
            $CPAN::Frontend->mywarn("META.yml does not seem to be conforming, cannot use it.\n");
            $self->{yaml_content} = +{};
        }
    }
    if (not exists $self->{yaml_content}{dynamic_config}
        or $self->{yaml_content}{dynamic_config}
       ) {
        $self->{yaml_content} = undef;
    }
    $self->debug(sprintf "yaml_content[%s]", $self->{yaml_content} || "UNDEF")
        if $CPAN::DEBUG;
    return $self->{yaml_content};
}

#-> sub CPAN::Distribution::prereq_pm ;
sub prereq_pm {
    my($self) = @_;
    $self->{prereq_pm_detected} ||= 0;
    CPAN->debug("ID[$self->{ID}]prereq_pm_detected[$self->{prereq_pm_detected}]") if $CPAN::DEBUG;
    return $self->{prereq_pm} if $self->{prereq_pm_detected};
    return unless $self->{writemakefile}  # no need to have succeeded
                                          # but we must have run it
        || $self->{modulebuild};
    unless ($self->{build_dir}) {
        return;
    }
    CPAN->debug(sprintf "writemakefile[%s]modulebuild[%s]",
                $self->{writemakefile}||"",
                $self->{modulebuild}||"",
               ) if $CPAN::DEBUG;
    my($req,$breq);
    if (my $yaml = $self->read_yaml) { # often dynamic_config prevents a result here
        $req =  $yaml->{requires} || {};
        $breq =  $yaml->{build_requires} || {};
        undef $req unless ref $req eq "HASH" && %$req;
        if ($req) {
            if ($yaml->{generated_by} &&
                $yaml->{generated_by} =~ /ExtUtils::MakeMaker version ([\d\._]+)/) {
                my $eummv = do { local $^W = 0; $1+0; };
                if ($eummv < 6.2501) {
                    # thanks to Slaven for digging that out: MM before
                    # that could be wrong because it could reflect a
                    # previous release
                    undef $req;
                }
            }
            my $areq;
            my $do_replace;
            while (my($k,$v) = each %{$req||{}}) {
                if ($v =~ /\d/) {
                    $areq->{$k} = $v;
                } elsif ($k =~ /[A-Za-z]/ &&
                         $v =~ /[A-Za-z]/ &&
                         $CPAN::META->exists("CPAN::Module",$v)
                        ) {
                    $CPAN::Frontend->mywarn("Suspicious key-value pair in META.yml's ".
                                            "requires hash: $k => $v; I'll take both ".
                                            "key and value as a module name\n");
                    $CPAN::Frontend->mysleep(1);
                    $areq->{$k} = 0;
                    $areq->{$v} = 0;
                    $do_replace++;
                }
            }
            $req = $areq if $do_replace;
        }
    }
    unless ($req || $breq) {
        my $build_dir;
        unless ( $build_dir = $self->{build_dir} ) {
            return;
        }
        my $makefile = File::Spec->catfile($build_dir,"Makefile");
        my $fh;
        if (-f $makefile
            and
            $fh = FileHandle->new("<$makefile\0")) {
            CPAN->debug("Getting prereq from Makefile") if $CPAN::DEBUG;
            local($/) = "\n";
            while (<$fh>) {
                last if /MakeMaker post_initialize section/;
                my($p) = m{^[\#]
                           \s+PREREQ_PM\s+=>\s+(.+)
                       }x;
                next unless $p;
                # warn "Found prereq expr[$p]";

                #  Regexp modified by A.Speer to remember actual version of file
                #  PREREQ_PM hash key wants, then add to
                while ( $p =~ m/(?:\s)([\w\:]+)=>(q\[.*?\]|undef),?/g ) {
                    # In case a prereq is mentioned twice, complain.
                    if ( defined $req->{$1} ) {
                        warn "Warning: PREREQ_PM mentions $1 more than once, ".
                            "last mention wins";
                    }
                    my($m,$n) = ($1,$2);
                    if ($n =~ /^q\[(.*?)\]$/) {
                        $n = $1;
                    }
                    $req->{$m} = $n;
                }
                last;
            }
        }
    }
    unless ($req || $breq) {
        my $build_dir = $self->{build_dir} or die "Panic: no build_dir?";
        my $buildfile = File::Spec->catfile($build_dir,"Build");
        if (-f $buildfile) {
            CPAN->debug("Found '$buildfile'") if $CPAN::DEBUG;
            my $build_prereqs = File::Spec->catfile($build_dir,"_build","prereqs");
            if (-f $build_prereqs) {
                CPAN->debug("Getting prerequisites from '$build_prereqs'") if $CPAN::DEBUG;
                my $content = do { local *FH;
                                   open FH, $build_prereqs
                                       or $CPAN::Frontend->mydie("Could not open ".
                                                                 "'$build_prereqs': $!");
                                   local $/;
                                   <FH>;
                               };
                my $bphash = eval $content;
                if ($@) {
                } else {
                    $req  = $bphash->{requires} || +{};
                    $breq = $bphash->{build_requires} || +{};
                }
            }
        }
    }
    if (-f "Build.PL"
        && ! -f "Makefile.PL"
        && ! exists $req->{"Module::Build"}
        && ! $CPAN::META->has_inst("Module::Build")) {
        $CPAN::Frontend->mywarn("  Warning: CPAN.pm discovered Module::Build as ".
                                "undeclared prerequisite.\n".
                                "  Adding it now as such.\n"
                               );
        $CPAN::Frontend->mysleep(5);
        $req->{"Module::Build"} = 0;
        delete $self->{writemakefile};
    }
    if ($req || $breq) {
        $self->{prereq_pm_detected}++;
        return $self->{prereq_pm} = { requires => $req, build_requires => $breq };
    }
}

#-> sub CPAN::Distribution::test ;
sub test {
    my($self) = @_;
    if (my $goto = $self->prefs->{goto}) {
        return $self->goto($goto);
    }
    $self->make;
    return if $self->prefs->{disabled} && ! $self->{force_update};
    if ($CPAN::Signal) {
      delete $self->{force_update};
      return;
    }
    # warn "XDEBUG: checking for notest: $self->{notest} $self";
    if ($self->{notest}) {
        $CPAN::Frontend->myprint("Skipping test because of notest pragma\n");
        return 1;
    }

    my $make = $self->{modulebuild} ? "Build" : "make";

    local $ENV{PERL5LIB} = defined($ENV{PERL5LIB})
                           ? $ENV{PERL5LIB}
                           : ($ENV{PERLLIB} || "");

    local $ENV{PERL5OPT} = defined $ENV{PERL5OPT} ? $ENV{PERL5OPT} : "";
    $CPAN::META->set_perl5lib;
    local $ENV{MAKEFLAGS}; # protect us from outer make calls

    $CPAN::Frontend->myprint("Running $make test\n");

  EXCUSE: {
        my @e;
        if ($self->{make} or $self->{later}) {
            # go ahead
        } else {
            push @e,
                "Make had some problems, won't test";
        }

        exists $self->{make} and
            (
             UNIVERSAL::can($self->{make},"failed") ?
             $self->{make}->failed :
             $self->{make} =~ /^NO/
            ) and push @e, "Can't test without successful make";
        $self->{badtestcnt} ||= 0;
        if ($self->{badtestcnt} > 0) {
            require Data::Dumper;
            CPAN->debug(sprintf "NOREPEAT[%s]", Data::Dumper::Dumper($self)) if $CPAN::DEBUG;
            push @e, "Won't repeat unsuccessful test during this command";
        }

        push @e, $self->{later} if $self->{later};
        push @e, $self->{configure_requires_later} if $self->{configure_requires_later};

        if (exists $self->{build_dir}) {
            if (exists $self->{make_test}) {
                if (
                    UNIVERSAL::can($self->{make_test},"failed") ?
                    $self->{make_test}->failed :
                    $self->{make_test} =~ /^NO/
                   ) {
                    if (
                        UNIVERSAL::can($self->{make_test},"commandid")
                        &&
                        $self->{make_test}->commandid == $CPAN::CurrentCommandId
                       ) {
                        push @e, "Has already been tested within this command";
                    }
                } else {
                    push @e, "Has already been tested successfully";
                    # if global "is_tested" has been cleared, we need to mark this to
                    # be added to PERL5LIB if not already installed
                    if ($self->tested_ok_but_not_installed) {
                        $CPAN::META->is_tested($self->{build_dir},$self->{make_test}{TIME});
                    }
                }
            }
        } elsif (!@e) {
            push @e, "Has no own directory";
        }
        $CPAN::Frontend->myprint(join "", map {"  $_\n"} @e) and return if @e;
        unless (chdir $self->{build_dir}) {
            push @e, "Couldn't chdir to '$self->{build_dir}': $!";
        }
        $CPAN::Frontend->mywarn(join "", map {"  $_\n"} @e) and return if @e;
    }
    $self->debug("Changed directory to $self->{build_dir}")
        if $CPAN::DEBUG;

    if ($^O eq 'MacOS') {
        Mac::BuildTools::make_test($self);
        return;
    }

    if ($self->{modulebuild}) {
        my $thm = CPAN::Shell->expand("Module","Test::Harness");
        my $v = $thm->inst_version;
        if (CPAN::Version->vlt($v,2.62)) {
            # XXX Eric Wilhelm reported this as a bug: klapperl:
            # Test::Harness 3.0 self-tests, so that should be 'unless
            # installing Test::Harness'
            unless ($self->id eq $thm->distribution->id) {
               $CPAN::Frontend->mywarn(qq{The version of your Test::Harness is only
  '$v', you need at least '2.62'. Please upgrade your Test::Harness.\n});
                $self->{make_test} = CPAN::Distrostatus->new("NO Test::Harness too old");
                return;
            }
        }
    }

    if ( ! $self->{force_update}  ) {
        # bypass actual tests if "trust_test_report_history" and have a report
        my $have_tested_fcn;
        if (   $CPAN::Config->{trust_test_report_history}
            && $CPAN::META->has_inst("CPAN::Reporter::History") 
            && ( $have_tested_fcn = CPAN::Reporter::History->can("have_tested" ))) {
            if ( my @reports = $have_tested_fcn->( dist => $self->base_id ) ) {
                # Do nothing if grade was DISCARD
                if ( $reports[-1]->{grade} =~ /^(?:PASS|UNKNOWN)$/ ) {
                    $self->{make_test} = CPAN::Distrostatus->new("YES");
                    # if global "is_tested" has been cleared, we need to mark this to
                    # be added to PERL5LIB if not already installed
                    if ($self->tested_ok_but_not_installed) {
                        $CPAN::META->is_tested($self->{build_dir},$self->{make_test}{TIME});
                    }
                    $CPAN::Frontend->myprint("Found prior test report -- OK\n");
                    return;
                }
                elsif ( $reports[-1]->{grade} =~ /^(?:FAIL|NA)$/ ) {
                    $self->{make_test} = CPAN::Distrostatus->new("NO");
                    $self->{badtestcnt}++;
                    $CPAN::Frontend->mywarn("Found prior test report -- NOT OK\n");
                    return;
                }
            }
        }
    }

    my $system;
    my $prefs_test = $self->prefs->{test};
    if (my $commandline
        = exists $prefs_test->{commandline} ? $prefs_test->{commandline} : "") {
        $system = $commandline;
        $ENV{PERL} = CPAN::find_perl;
    } elsif ($self->{modulebuild}) {
        $system = sprintf "%s test", $self->_build_command();
        unless (-e "Build") {
            my $id = $self->pretty_id;
            $CPAN::Frontend->mywarn("Alert: no 'Build' file found while trying to test '$id'");
        }
    } else {
        $system = join " ", $self->_make_command(), "test";
    }
    my $make_test_arg = $self->_make_phase_arg("test");
    $system = sprintf("%s%s",
                      $system,
                      $make_test_arg ? " $make_test_arg" : "",
                     );
    my($tests_ok);
    my %env;
    while (my($k,$v) = each %ENV) {
        next unless defined $v;
        $env{$k} = $v;
    }
    local %ENV = %env;
    my $test_env;
    if ($self->prefs->{test}) {
        $test_env = $self->prefs->{test}{env};
    }
    if ($test_env) {
        for my $e (keys %$test_env) {
            $ENV{$e} = $test_env->{$e};
        }
    }
    my $expect_model = $self->_prefs_with_expect("test");
    my $want_expect = 0;
    if ( $expect_model && @{$expect_model->{talk}} ) {
        my $can_expect = $CPAN::META->has_inst("Expect");
        if ($can_expect) {
            $want_expect = 1;
        } else {
            $CPAN::Frontend->mywarn("Expect not installed, falling back to ".
                                    "testing without\n");
        }
    }
    if ($want_expect) {
        if ($self->_should_report('test')) {
            $CPAN::Frontend->mywarn("Reporting via CPAN::Reporter is currently ".
                                    "not supported when distroprefs specify ".
                                    "an interactive test\n");
        }
        $tests_ok = $self->_run_via_expect($system,'test',$expect_model) == 0;
    } elsif ( $self->_should_report('test') ) {
        $tests_ok = CPAN::Reporter::test($self, $system);
    } else {
        $tests_ok = system($system) == 0;
    }
    $self->introduce_myself;
    if ( $tests_ok ) {
        {
            my @prereq;

            # local $CPAN::DEBUG = 16; # Distribution
            for my $m (keys %{$self->{sponsored_mods}}) {
                next unless $self->{sponsored_mods}{$m} > 0;
                my $m_obj = CPAN::Shell->expand("Module",$m) or next;
                # XXX we need available_version which reflects
                # $ENV{PERL5LIB} so that already tested but not yet
                # installed modules are counted.
                my $available_version = $m_obj->available_version;
                my $available_file = $m_obj->available_file;
                if ($available_version &&
                    !CPAN::Version->vlt($available_version,$self->{prereq_pm}{$m})
                   ) {
                    CPAN->debug("m[$m] good enough available_version[$available_version]")
                        if $CPAN::DEBUG;
                } elsif ($available_file
                         && (
                             !$self->{prereq_pm}{$m}
                             ||
                             $self->{prereq_pm}{$m} == 0
                            )
                        ) {
                    # lex Class::Accessor::Chained::Fast which has no $VERSION
                    CPAN->debug("m[$m] have available_file[$available_file]")
                        if $CPAN::DEBUG;
                } else {
                    push @prereq, $m;
                }
            }
            if (@prereq) {
                my $cnt = @prereq;
                my $which = join ",", @prereq;
                my $but = $cnt == 1 ? "one dependency not OK ($which)" :
                    "$cnt dependencies missing ($which)";
                $CPAN::Frontend->mywarn("Tests succeeded but $but\n");
                $self->{make_test} = CPAN::Distrostatus->new("NO $but");
                $self->store_persistent_state;
                return $self->goodbye("[dependencies] -- NA");
            }
        }

        $CPAN::Frontend->myprint("  $system -- OK\n");
        $self->{make_test} = CPAN::Distrostatus->new("YES");
        $CPAN::META->is_tested($self->{build_dir},$self->{make_test}{TIME});
        # probably impossible to need the next line because badtestcnt
        # has a lifespan of one command
        delete $self->{badtestcnt};
    } else {
        $self->{make_test} = CPAN::Distrostatus->new("NO");
        $self->{badtestcnt}++;
        $CPAN::Frontend->mywarn("  $system -- NOT OK\n");
        CPAN::Shell->optprint
              ("hint",
               sprintf
               ("//hint// to see the cpan-testers results for installing this module, try:
  reports %s\n",
                $self->pretty_id));
    }
    $self->store_persistent_state;
}

sub _prefs_with_expect {
    my($self,$where) = @_;
    return unless my $prefs = $self->prefs;
    return unless my $where_prefs = $prefs->{$where};
    if ($where_prefs->{expect}) {
        return {
                mode => "deterministic",
                timeout => 15,
                talk => $where_prefs->{expect},
               };
    } elsif ($where_prefs->{"eexpect"}) {
        return $where_prefs->{"eexpect"};
    }
    return;
}

#-> sub CPAN::Distribution::clean ;
sub clean {
    my($self) = @_;
    my $make = $self->{modulebuild} ? "Build" : "make";
    $CPAN::Frontend->myprint("Running $make clean\n");
    unless (exists $self->{archived}) {
        $CPAN::Frontend->mywarn("Distribution seems to have never been unzipped".
                                "/untarred, nothing done\n");
        return 1;
    }
    unless (exists $self->{build_dir}) {
        $CPAN::Frontend->mywarn("Distribution has no own directory, nothing to do.\n");
        return 1;
    }
    if (exists $self->{writemakefile}
        and $self->{writemakefile}->failed
       ) {
        $CPAN::Frontend->mywarn("No Makefile, don't know how to 'make clean'\n");
        return 1;
    }
  EXCUSE: {
        my @e;
        exists $self->{make_clean} and $self->{make_clean} eq "YES" and
            push @e, "make clean already called once";
        $CPAN::Frontend->myprint(join "", map {"  $_\n"} @e) and return if @e;
    }
    chdir $self->{build_dir} or
        Carp::confess("Couldn't chdir to $self->{build_dir}: $!");
    $self->debug("Changed directory to $self->{build_dir}") if $CPAN::DEBUG;

    if ($^O eq 'MacOS') {
        Mac::BuildTools::make_clean($self);
        return;
    }

    my $system;
    if ($self->{modulebuild}) {
        unless (-f "Build") {
            my $cwd = CPAN::anycwd();
            $CPAN::Frontend->mywarn("Alert: no Build file available for 'clean $self->{id}".
                                    " in cwd[$cwd]. Danger, Will Robinson!");
            $CPAN::Frontend->mysleep(5);
        }
        $system = sprintf "%s clean", $self->_build_command();
    } else {
        $system  = join " ", $self->_make_command(), "clean";
    }
    my $system_ok = system($system) == 0;
    $self->introduce_myself;
    if ( $system_ok ) {
      $CPAN::Frontend->myprint("  $system -- OK\n");

      # $self->force;

      # Jost Krieger pointed out that this "force" was wrong because
      # it has the effect that the next "install" on this distribution
      # will untar everything again. Instead we should bring the
      # object's state back to where it is after untarring.

      for my $k (qw(
                    force_update
                    install
                    writemakefile
                    make
                    make_test
                   )) {
          delete $self->{$k};
      }
      $self->{make_clean} = CPAN::Distrostatus->new("YES");

    } else {
      # Hmmm, what to do if make clean failed?

      $self->{make_clean} = CPAN::Distrostatus->new("NO");
      $CPAN::Frontend->mywarn(qq{  $system -- NOT OK\n});

      # 2006-02-27: seems silly to me to force a make now
      # $self->force("make"); # so that this directory won't be used again

    }
    $self->store_persistent_state;
}

#-> sub CPAN::Distribution::goto ;
sub goto {
    my($self,$goto) = @_;
    $goto = $self->normalize($goto);
    my $why = sprintf(
                      "Goto '$goto' via prefs file '%s' doc %d",
                      $self->{prefs_file},
                      $self->{prefs_file_doc},
                     );
    $self->{unwrapped} = CPAN::Distrostatus->new("NO $why");
    # 2007-07-16 akoenig : Better than NA would be if we could inherit
    # the status of the $goto distro but given the exceptional nature
    # of 'goto' I feel reluctant to implement it
    my $goodbye_message = "[goto] -- NA $why";
    $self->goodbye($goodbye_message);

    # inject into the queue

    CPAN::Queue->delete($self->id);
    CPAN::Queue->jumpqueue({qmod => $goto, reqtype => $self->{reqtype}});

    # and run where we left off

    my($method) = (caller(1))[3];
    CPAN->instance("CPAN::Distribution",$goto)->$method();
    CPAN::Queue->delete_first($goto);
}

#-> sub CPAN::Distribution::install ;
sub install {
    my($self) = @_;
    if (my $goto = $self->prefs->{goto}) {
        return $self->goto($goto);
    }
    unless ($self->{badtestcnt}) {
        $self->test;
    }
    if ($CPAN::Signal) {
      delete $self->{force_update};
      return;
    }
    my $make = $self->{modulebuild} ? "Build" : "make";
    $CPAN::Frontend->myprint("Running $make install\n");
  EXCUSE: {
        my @e;
        if ($self->{make} or $self->{later}) {
            # go ahead
        } else {
            push @e,
                "Make had some problems, won't install";
        }

        exists $self->{make} and
            (
             UNIVERSAL::can($self->{make},"failed") ?
             $self->{make}->failed :
             $self->{make} =~ /^NO/
            ) and
            push @e, "Make had returned bad status, install seems impossible";

        if (exists $self->{build_dir}) {
        } elsif (!@e) {
            push @e, "Has no own directory";
        }

        if (exists $self->{make_test} and
            (
             UNIVERSAL::can($self->{make_test},"failed") ?
             $self->{make_test}->failed :
             $self->{make_test} =~ /^NO/
            )) {
            if ($self->{force_update}) {
                $self->{make_test}->text("FAILED but failure ignored because ".
                                         "'force' in effect");
            } else {
                push @e, "make test had returned bad status, ".
                    "won't install without force"
            }
        }
        if (exists $self->{install}) {
            if (UNIVERSAL::can($self->{install},"text") ?
                $self->{install}->text eq "YES" :
                $self->{install} =~ /^YES/
               ) {
                $CPAN::Frontend->myprint("  Already done\n");
                $CPAN::META->is_installed($self->{build_dir});
                return 1;
            } else {
                # comment in Todo on 2006-02-11; maybe retry?
                push @e, "Already tried without success";
            }
        }

        push @e, $self->{later} if $self->{later};
        push @e, $self->{configure_requires_later} if $self->{configure_requires_later};

        $CPAN::Frontend->myprint(join "", map {"  $_\n"} @e) and return if @e;
        unless (chdir $self->{build_dir}) {
            push @e, "Couldn't chdir to '$self->{build_dir}': $!";
        }
        $CPAN::Frontend->mywarn(join "", map {"  $_\n"} @e) and return if @e;
    }
    $self->debug("Changed directory to $self->{build_dir}")
        if $CPAN::DEBUG;

    if ($^O eq 'MacOS') {
        Mac::BuildTools::make_install($self);
        return;
    }

    my $system;
    if (my $commandline = $self->prefs->{install}{commandline}) {
        $system = $commandline;
        $ENV{PERL} = CPAN::find_perl;
    } elsif ($self->{modulebuild}) {
        my($mbuild_install_build_command) =
            exists $CPAN::HandleConfig::keys{mbuild_install_build_command} &&
                $CPAN::Config->{mbuild_install_build_command} ?
                    $CPAN::Config->{mbuild_install_build_command} :
                        $self->_build_command();
        $system = sprintf("%s install %s",
                          $mbuild_install_build_command,
                          $CPAN::Config->{mbuild_install_arg},
                         );
    } else {
        my($make_install_make_command) =
            CPAN::HandleConfig->prefs_lookup($self,
                                             q{make_install_make_command})
                  || $self->_make_command();
        $system = sprintf("%s install %s",
                          $make_install_make_command,
                          $CPAN::Config->{make_install_arg},
                         );
    }

    my($stderr) = $^O eq "MSWin32" ? "" : " 2>&1 ";
    my $brip = CPAN::HandleConfig->prefs_lookup($self,
                                                q{build_requires_install_policy});
    $brip ||="ask/yes";
    my $id = $self->id;
    my $reqtype = $self->{reqtype} ||= "c"; # in doubt it was a command
    my $want_install = "yes";
    if ($reqtype eq "b") {
        if ($brip eq "no") {
            $want_install = "no";
        } elsif ($brip =~ m|^ask/(.+)|) {
            my $default = $1;
            $default = "yes" unless $default =~ /^(y|n)/i;
            $want_install =
                CPAN::Shell::colorable_makemaker_prompt
                      ("$id is just needed temporarily during building or testing. ".
                       "Do you want to install it permanently? (Y/n)",
                       $default);
        }
    }
    unless ($want_install =~ /^y/i) {
        my $is_only = "is only 'build_requires'";
        $CPAN::Frontend->mywarn("Not installing because $is_only\n");
        $self->{install} = CPAN::Distrostatus->new("NO -- $is_only");
        delete $self->{force_update};
        return;
    }
    local $ENV{PERL5LIB} = defined($ENV{PERL5LIB})
                           ? $ENV{PERL5LIB}
                           : ($ENV{PERLLIB} || "");

    local $ENV{PERL5OPT} = defined $ENV{PERL5OPT} ? $ENV{PERL5OPT} : "";
    $CPAN::META->set_perl5lib;
    my($pipe) = FileHandle->new("$system $stderr |") || Carp::croak
("Can't execute $system: $!");
    my($makeout) = "";
    while (<$pipe>) {
        print $_; # intentionally NOT use Frontend->myprint because it
                  # looks irritating when we markup in color what we
                  # just pass through from an external program
        $makeout .= $_;
    }
    $pipe->close;
    my $close_ok = $? == 0;
    $self->introduce_myself;
    if ( $close_ok ) {
        $CPAN::Frontend->myprint("  $system -- OK\n");
        $CPAN::META->is_installed($self->{build_dir});
        $self->{install} = CPAN::Distrostatus->new("YES");
    } else {
        $self->{install} = CPAN::Distrostatus->new("NO");
        $CPAN::Frontend->mywarn("  $system -- NOT OK\n");
        my $mimc =
            CPAN::HandleConfig->prefs_lookup($self,
                                             q{make_install_make_command});
        if (
            $makeout =~ /permission/s
            && $> > 0
            && (
                ! $mimc
                || $mimc eq (CPAN::HandleConfig->prefs_lookup($self,
                                                              q{make}))
               )
           ) {
            $CPAN::Frontend->myprint(
                                     qq{----\n}.
                                     qq{  You may have to su }.
                                     qq{to root to install the package\n}.
                                     qq{  (Or you may want to run something like\n}.
                                     qq{    o conf make_install_make_command 'sudo make'\n}.
                                     qq{  to raise your permissions.}
                                    );
        }
    }
    delete $self->{force_update};
    $self->store_persistent_state;
}

sub introduce_myself {
    my($self) = @_;
    $CPAN::Frontend->myprint(sprintf("  %s\n",$self->pretty_id));
}

#-> sub CPAN::Distribution::dir ;
sub dir {
    shift->{build_dir};
}

#-> sub CPAN::Distribution::perldoc ;
sub perldoc {
    my($self) = @_;

    my($dist) = $self->id;
    my $package = $self->called_for;

    $self->_display_url( $CPAN::Defaultdocs . $package );
}

#-> sub CPAN::Distribution::_check_binary ;
sub _check_binary {
    my ($dist,$shell,$binary) = @_;
    my ($pid,$out);

    $CPAN::Frontend->myprint(qq{ + _check_binary($binary)\n})
      if $CPAN::DEBUG;

    if ($CPAN::META->has_inst("File::Which")) {
        return File::Which::which($binary);
    } else {
        local *README;
        $pid = open README, "which $binary|"
            or $CPAN::Frontend->mywarn(qq{Could not fork 'which $binary': $!\n});
        return unless $pid;
        while (<README>) {
            $out .= $_;
        }
        close README
            or $CPAN::Frontend->mywarn("Could not run 'which $binary': $!\n")
                and return;
    }

    $CPAN::Frontend->myprint(qq{   + $out \n})
      if $CPAN::DEBUG && $out;

    return $out;
}

#-> sub CPAN::Distribution::_display_url ;
sub _display_url {
    my($self,$url) = @_;
    my($res,$saved_file,$pid,$out);

    $CPAN::Frontend->myprint(qq{ + _display_url($url)\n})
      if $CPAN::DEBUG;

    # should we define it in the config instead?
    my $html_converter = "html2text.pl";

    my $web_browser = $CPAN::Config->{'lynx'} || undef;
    my $web_browser_out = $web_browser
        ? CPAN::Distribution->_check_binary($self,$web_browser)
        : undef;

    if ($web_browser_out) {
        # web browser found, run the action
        my $browser = CPAN::HandleConfig->safe_quote($CPAN::Config->{'lynx'});
        $CPAN::Frontend->myprint(qq{system[$browser $url]})
            if $CPAN::DEBUG;
        $CPAN::Frontend->myprint(qq{
Displaying URL
  $url
with browser $browser
});
        $CPAN::Frontend->mysleep(1);
        system("$browser $url");
        if ($saved_file) { 1 while unlink($saved_file) }
    } else {
        # web browser not found, let's try text only
        my $html_converter_out =
            CPAN::Distribution->_check_binary($self,$html_converter);
        $html_converter_out = CPAN::HandleConfig->safe_quote($html_converter_out);

        if ($html_converter_out ) {
            # html2text found, run it
            $saved_file = CPAN::Distribution->_getsave_url( $self, $url );
            $CPAN::Frontend->mydie(qq{ERROR: problems while getting $url\n})
                unless defined($saved_file);

            local *README;
            $pid = open README, "$html_converter $saved_file |"
                or $CPAN::Frontend->mydie(qq{
Could not fork '$html_converter $saved_file': $!});
            my($fh,$filename);
            if ($CPAN::META->has_usable("File::Temp")) {
                $fh = File::Temp->new(
                                      dir      => File::Spec->tmpdir,
                                      template => 'cpan_htmlconvert_XXXX',
                                      suffix => '.txt',
                                      unlink => 0,
                                     );
                $filename = $fh->filename;
            } else {
                $filename = "cpan_htmlconvert_$$.txt";
                $fh = FileHandle->new();
                open $fh, ">$filename" or die;
            }
            while (<README>) {
                $fh->print($_);
            }
            close README or
                $CPAN::Frontend->mydie(qq{Could not run '$html_converter $saved_file': $!});
            my $tmpin = $fh->filename;
            $CPAN::Frontend->myprint(sprintf(qq{
Run '%s %s' and
saved output to %s\n},
                                             $html_converter,
                                             $saved_file,
                                             $tmpin,
                                            )) if $CPAN::DEBUG;
            close $fh;
            local *FH;
            open FH, $tmpin
                or $CPAN::Frontend->mydie(qq{Could not open "$tmpin": $!});
            my $fh_pager = FileHandle->new;
            local($SIG{PIPE}) = "IGNORE";
            my $pager = $CPAN::Config->{'pager'} || "cat";
            $fh_pager->open("|$pager")
                or $CPAN::Frontend->mydie(qq{
Could not open pager '$pager': $!});
            $CPAN::Frontend->myprint(qq{
Displaying URL
  $url
with pager "$pager"
});
            $CPAN::Frontend->mysleep(1);
            $fh_pager->print(<FH>);
            $fh_pager->close;
        } else {
            # coldn't find the web browser or html converter
            $CPAN::Frontend->myprint(qq{
You need to install lynx or $html_converter to use this feature.});
        }
    }
}

#-> sub CPAN::Distribution::_getsave_url ;
sub _getsave_url {
    my($dist, $shell, $url) = @_;

    $CPAN::Frontend->myprint(qq{ + _getsave_url($url)\n})
      if $CPAN::DEBUG;

    my($fh,$filename);
    if ($CPAN::META->has_usable("File::Temp")) {
        $fh = File::Temp->new(
                              dir      => File::Spec->tmpdir,
                              template => "cpan_getsave_url_XXXX",
                              suffix => ".html",
                              unlink => 0,
                             );
        $filename = $fh->filename;
    } else {
        $fh = FileHandle->new;
        $filename = "cpan_getsave_url_$$.html";
    }
    my $tmpin = $filename;
    if ($CPAN::META->has_usable('LWP')) {
        $CPAN::Frontend->myprint("Fetching with LWP:
  $url
");
        my $Ua;
        CPAN::LWP::UserAgent->config;
        eval { $Ua = CPAN::LWP::UserAgent->new; };
        if ($@) {
            $CPAN::Frontend->mywarn("ERROR: CPAN::LWP::UserAgent->new dies with $@\n");
            return;
        } else {
            my($var);
            $Ua->proxy('http', $var)
                if $var = $CPAN::Config->{http_proxy} || $ENV{http_proxy};
            $Ua->no_proxy($var)
                if $var = $CPAN::Config->{no_proxy} || $ENV{no_proxy};
        }

        my $req = HTTP::Request->new(GET => $url);
        $req->header('Accept' => 'text/html');
        my $res = $Ua->request($req);
        if ($res->is_success) {
            $CPAN::Frontend->myprint(" + request successful.\n")
                if $CPAN::DEBUG;
            print $fh $res->content;
            close $fh;
            $CPAN::Frontend->myprint(qq{ + saved content to $tmpin \n})
                if $CPAN::DEBUG;
            return $tmpin;
        } else {
            $CPAN::Frontend->myprint(sprintf(
                                             "LWP failed with code[%s], message[%s]\n",
                                             $res->code,
                                             $res->message,
                                            ));
            return;
        }
    } else {
        $CPAN::Frontend->mywarn("  LWP not available\n");
        return;
    }
}

#-> sub CPAN::Distribution::_build_command
sub _build_command {
    my($self) = @_;
    if ($^O eq "MSWin32") { # special code needed at least up to
                            # Module::Build 0.2611 and 0.2706; a fix
                            # in M:B has been promised 2006-01-30
        my($perl) = $self->perl or $CPAN::Frontend->mydie("Couldn't find executable perl\n");
        return "$perl ./Build";
    }
    return "./Build";
}

#-> sub CPAN::Distribution::_should_report
sub _should_report {
    my($self, $phase) = @_;
    die "_should_report() requires a 'phase' argument"
        if ! defined $phase;

    # configured
    my $test_report = CPAN::HandleConfig->prefs_lookup($self,
                                                       q{test_report});
    return unless $test_report;

    # don't repeat if we cached a result
    return $self->{should_report}
        if exists $self->{should_report};

    # don't report if we generated a Makefile.PL
    if ( $self->{had_no_makefile_pl} ) {
        $CPAN::Frontend->mywarn(
            "Will not send CPAN Testers report with generated Makefile.PL.\n"
        );
        return $self->{should_report} = 0;
    }

    # available
    if ( ! $CPAN::META->has_inst("CPAN::Reporter")) {
        $CPAN::Frontend->mywarn(
            "CPAN::Reporter not installed.  No reports will be sent.\n"
        );
        return $self->{should_report} = 0;
    }

    # capable
    my $crv = CPAN::Reporter->VERSION;
    if ( CPAN::Version->vlt( $crv, 0.99 ) ) {
        # don't cache $self->{should_report} -- need to check each phase
        if ( $phase eq 'test' ) {
            return 1;
        }
        else {
            $CPAN::Frontend->mywarn(
                "Reporting on the '$phase' phase requires CPAN::Reporter 0.99, but \n" .
                "you only have version $crv\.  Only 'test' phase reports will be sent.\n"
            );
            return;
        }
    }

    # appropriate
    if ($self->is_dot_dist) {
        $CPAN::Frontend->mywarn("Reporting via CPAN::Reporter is disabled ".
                                "for local directories\n");
        return $self->{should_report} = 0;
    }
    if ($self->prefs->{patches}
        &&
        @{$self->prefs->{patches}}
        &&
        $self->{patched}
       ) {
        $CPAN::Frontend->mywarn("Reporting via CPAN::Reporter is disabled ".
                                "when the source has been patched\n");
        return $self->{should_report} = 0;
    }

    # proceed and cache success
    return $self->{should_report} = 1;
}

#-> sub CPAN::Distribution::reports
sub reports {
    my($self) = @_;
    my $pathname = $self->id;
    $CPAN::Frontend->myprint("Distribution: $pathname\n");

    unless ($CPAN::META->has_inst("CPAN::DistnameInfo")) {
        $CPAN::Frontend->mydie("CPAN::DistnameInfo not installed; cannot continue");
    }
    unless ($CPAN::META->has_usable("LWP")) {
        $CPAN::Frontend->mydie("LWP not installed; cannot continue");
    }
    unless ($CPAN::META->has_usable("File::Temp")) {
        $CPAN::Frontend->mydie("File::Temp not installed; cannot continue");
    }

    my $d = CPAN::DistnameInfo->new($pathname);

    my $dist      = $d->dist;      # "CPAN-DistnameInfo"
    my $version   = $d->version;   # "0.02"
    my $maturity  = $d->maturity;  # "released"
    my $filename  = $d->filename;  # "CPAN-DistnameInfo-0.02.tar.gz"
    my $cpanid    = $d->cpanid;    # "GBARR"
    my $distvname = $d->distvname; # "CPAN-DistnameInfo-0.02"

    my $url = sprintf "http://cpantesters.perl.org/show/%s.yaml", $dist;

    CPAN::LWP::UserAgent->config;
    my $Ua;
    eval { $Ua = CPAN::LWP::UserAgent->new; };
    if ($@) {
        $CPAN::Frontend->mydie("CPAN::LWP::UserAgent->new dies with $@\n");
    }
    $CPAN::Frontend->myprint("Fetching '$url'...");
    my $resp = $Ua->get($url);
    unless ($resp->is_success) {
        $CPAN::Frontend->mydie(sprintf "Could not download '%s': %s\n", $url, $resp->code);
    }
    $CPAN::Frontend->myprint("DONE\n\n");
    my $yaml = $resp->content;
    # was fuer ein Umweg!
    my $fh = File::Temp->new(
                             dir      => File::Spec->tmpdir,
                             template => 'cpan_reports_XXXX',
                             suffix => '.yaml',
                             unlink => 0,
                            );
    my $tfilename = $fh->filename;
    print $fh $yaml;
    close $fh or $CPAN::Frontend->mydie("Could not close '$tfilename': $!");
    my $unserialized = CPAN->_yaml_loadfile($tfilename)->[0];
    unlink $tfilename or $CPAN::Frontend->mydie("Could not unlink '$tfilename': $!");
    my %other_versions;
    my $this_version_seen;
    for my $rep (@$unserialized) {
        my $rversion = $rep->{version};
        if ($rversion eq $version) {
            unless ($this_version_seen++) {
                $CPAN::Frontend->myprint ("$rep->{version}:\n");
            }
            $CPAN::Frontend->myprint
                (sprintf("%1s%1s%-4s %s on %s %s (%s)\n",
                         $rep->{archname} eq $Config::Config{archname}?"*":"",
                         $rep->{action}eq"PASS"?"+":$rep->{action}eq"FAIL"?"-":"",
                         $rep->{action},
                         $rep->{perl},
                         ucfirst $rep->{osname},
                         $rep->{osvers},
                         $rep->{archname},
                        ));
        } else {
            $other_versions{$rep->{version}}++;
        }
    }
    unless ($this_version_seen) {
        $CPAN::Frontend->myprint("No reports found for version '$version'
Reports for other versions:\n");
        for my $v (sort keys %other_versions) {
            $CPAN::Frontend->myprint(" $v\: $other_versions{$v}\n");
        }
    }
    $url =~ s/\.yaml/.html/;
    $CPAN::Frontend->myprint("See $url for details\n");
}

package CPAN::Bundle;
use strict;

sub look {
    my $self = shift;
    $CPAN::Frontend->myprint($self->as_string);
}

#-> CPAN::Bundle::undelay
sub undelay {
    my $self = shift;
    delete $self->{later};
    for my $c ( $self->contains ) {
        my $obj = CPAN::Shell->expandany($c) or next;
        $obj->undelay;
    }
}

# mark as dirty/clean
#-> sub CPAN::Bundle::color_cmd_tmps ;
sub color_cmd_tmps {
    my($self) = shift;
    my($depth) = shift || 0;
    my($color) = shift || 0;
    my($ancestors) = shift || [];
    # a module needs to recurse to its cpan_file, a distribution needs
    # to recurse into its prereq_pms, a bundle needs to recurse into its modules

    return if exists $self->{incommandcolor}
        && $color==1
        && $self->{incommandcolor}==$color;
    if ($depth>=$CPAN::MAX_RECURSION) {
        die(CPAN::Exception::RecursiveDependency->new($ancestors));
    }
    # warn "color_cmd_tmps $depth $color " . $self->id; # sleep 1;

    for my $c ( $self->contains ) {
        my $obj = CPAN::Shell->expandany($c) or next;
        CPAN->debug("c[$c]obj[$obj]") if $CPAN::DEBUG;
        $obj->color_cmd_tmps($depth+1,$color,[@$ancestors, $self->id]);
    }
    # never reached code?
    #if ($color==0) {
      #delete $self->{badtestcnt};
    #}
    $self->{incommandcolor} = $color;
}

#-> sub CPAN::Bundle::as_string ;
sub as_string {
    my($self) = @_;
    $self->contains;
    # following line must be "=", not "||=" because we have a moving target
    $self->{INST_VERSION} = $self->inst_version;
    return $self->SUPER::as_string;
}

#-> sub CPAN::Bundle::contains ;
sub contains {
    my($self) = @_;
    my($inst_file) = $self->inst_file || "";
    my($id) = $self->id;
    $self->debug("inst_file[$inst_file]id[$id]") if $CPAN::DEBUG;
    if ($inst_file && CPAN::Version->vlt($self->inst_version,$self->cpan_version)) {
        undef $inst_file;
    }
    unless ($inst_file) {
        # Try to get at it in the cpan directory
        $self->debug("no inst_file") if $CPAN::DEBUG;
        my $cpan_file;
        $CPAN::Frontend->mydie("I don't know a bundle with ID $id\n") unless
              $cpan_file = $self->cpan_file;
        if ($cpan_file eq "N/A") {
            $CPAN::Frontend->mydie("Bundle $id not found on disk and not on CPAN.
  Maybe stale symlink? Maybe removed during session? Giving up.\n");
        }
        my $dist = $CPAN::META->instance('CPAN::Distribution',
                                         $self->cpan_file);
        $self->debug("before get id[$dist->{ID}]") if $CPAN::DEBUG;
        $dist->get;
        $self->debug("after get id[$dist->{ID}]") if $CPAN::DEBUG;
        my($todir) = $CPAN::Config->{'cpan_home'};
        my(@me,$from,$to,$me);
        @me = split /::/, $self->id;
        $me[-1] .= ".pm";
        $me = File::Spec->catfile(@me);
        $from = $self->find_bundle_file($dist->{build_dir},join('/',@me));
        $to = File::Spec->catfile($todir,$me);
        File::Path::mkpath(File::Basename::dirname($to));
        File::Copy::copy($from, $to)
              or Carp::confess("Couldn't copy $from to $to: $!");
        $inst_file = $to;
    }
    my @result;
    my $fh = FileHandle->new;
    local $/ = "\n";
    open($fh,$inst_file) or die "Could not open '$inst_file': $!";
    my $in_cont = 0;
    $self->debug("inst_file[$inst_file]") if $CPAN::DEBUG;
    while (<$fh>) {
        $in_cont = m/^=(?!head1\s+(?i-xsm:CONTENTS))/ ? 0 :
            m/^=head1\s+(?i-xsm:CONTENTS)/ ? 1 : $in_cont;
        next unless $in_cont;
        next if /^=/;
        s/\#.*//;
        next if /^\s+$/;
        chomp;
        push @result, (split " ", $_, 2)[0];
    }
    close $fh;
    delete $self->{STATUS};
    $self->{CONTAINS} = \@result;
    $self->debug("CONTAINS[@result]") if $CPAN::DEBUG;
    unless (@result) {
        $CPAN::Frontend->mywarn(qq{
The bundle file "$inst_file" may be a broken
bundlefile. It seems not to contain any bundle definition.
Please check the file and if it is bogus, please delete it.
Sorry for the inconvenience.
});
    }
    @result;
}

#-> sub CPAN::Bundle::find_bundle_file
# $where is in local format, $what is in unix format
sub find_bundle_file {
    my($self,$where,$what) = @_;
    $self->debug("where[$where]what[$what]") if $CPAN::DEBUG;
### The following two lines let CPAN.pm become Bundle/CPAN.pm :-(
###    my $bu = File::Spec->catfile($where,$what);
###    return $bu if -f $bu;
    my $manifest = File::Spec->catfile($where,"MANIFEST");
    unless (-f $manifest) {
        require ExtUtils::Manifest;
        my $cwd = CPAN::anycwd();
        $self->safe_chdir($where);
        ExtUtils::Manifest::mkmanifest();
        $self->safe_chdir($cwd);
    }
    my $fh = FileHandle->new($manifest)
        or Carp::croak("Couldn't open $manifest: $!");
    local($/) = "\n";
    my $bundle_filename = $what;
    $bundle_filename =~ s|Bundle.*/||;
    my $bundle_unixpath;
    while (<$fh>) {
        next if /^\s*\#/;
        my($file) = /(\S+)/;
        if ($file =~ m|\Q$what\E$|) {
            $bundle_unixpath = $file;
            # return File::Spec->catfile($where,$bundle_unixpath); # bad
            last;
        }
        # retry if she managed to have no Bundle directory
        $bundle_unixpath = $file if $file =~ m|\Q$bundle_filename\E$|;
    }
    return File::Spec->catfile($where, split /\//, $bundle_unixpath)
        if $bundle_unixpath;
    Carp::croak("Couldn't find a Bundle file in $where");
}

# needs to work quite differently from Module::inst_file because of
# cpan_home/Bundle/ directory and the possibility that we have
# shadowing effect. As it makes no sense to take the first in @INC for
# Bundles, we parse them all for $VERSION and take the newest.

#-> sub CPAN::Bundle::inst_file ;
sub inst_file {
    my($self) = @_;
    my($inst_file);
    my(@me);
    @me = split /::/, $self->id;
    $me[-1] .= ".pm";
    my($incdir,$bestv);
    foreach $incdir ($CPAN::Config->{'cpan_home'},@INC) {
        my $parsefile = File::Spec->catfile($incdir, @me);
        CPAN->debug("parsefile[$parsefile]") if $CPAN::DEBUG;
        next unless -f $parsefile;
        my $have = eval { MM->parse_version($parsefile); };
        if ($@) {
            $CPAN::Frontend->mywarn("Error while parsing version number in file '$parsefile'\n");
        }
        if (!$bestv || CPAN::Version->vgt($have,$bestv)) {
            $self->{INST_FILE} = $parsefile;
            $self->{INST_VERSION} = $bestv = $have;
        }
    }
    $self->{INST_FILE};
}

#-> sub CPAN::Bundle::inst_version ;
sub inst_version {
    my($self) = @_;
    $self->inst_file; # finds INST_VERSION as side effect
    $self->{INST_VERSION};
}

#-> sub CPAN::Bundle::rematein ;
sub rematein {
    my($self,$meth) = @_;
    $self->debug("self[$self] meth[$meth]") if $CPAN::DEBUG;
    my($id) = $self->id;
    Carp::croak "Can't $meth $id, don't have an associated bundle file. :-(\n"
        unless $self->inst_file || $self->cpan_file;
    my($s,%fail);
    for $s ($self->contains) {
        my($type) = $s =~ m|/| ? 'CPAN::Distribution' :
            $s =~ m|^Bundle::| ? 'CPAN::Bundle' : 'CPAN::Module';
        if ($type eq 'CPAN::Distribution') {
            $CPAN::Frontend->mywarn(qq{
The Bundle }.$self->id.qq{ contains
explicitly a file '$s'.
Going to $meth that.
});
            $CPAN::Frontend->mysleep(5);
        }
        # possibly noisy action:
        $self->debug("type[$type] s[$s]") if $CPAN::DEBUG;
        my $obj = $CPAN::META->instance($type,$s);
        $obj->{reqtype} = $self->{reqtype};
        $obj->$meth();
    }
}

# If a bundle contains another that contains an xs_file we have here,
# we just don't bother I suppose
#-> sub CPAN::Bundle::xs_file
sub xs_file {
    return 0;
}

#-> sub CPAN::Bundle::force ;
sub fforce   { shift->rematein('fforce',@_); }
#-> sub CPAN::Bundle::force ;
sub force   { shift->rematein('force',@_); }
#-> sub CPAN::Bundle::notest ;
sub notest  { shift->rematein('notest',@_); }
#-> sub CPAN::Bundle::get ;
sub get     { shift->rematein('get',@_); }
#-> sub CPAN::Bundle::make ;
sub make    { shift->rematein('make',@_); }
#-> sub CPAN::Bundle::test ;
sub test    {
    my $self = shift;
    # $self->{badtestcnt} ||= 0;
    $self->rematein('test',@_);
}
#-> sub CPAN::Bundle::install ;
sub install {
  my $self = shift;
  $self->rematein('install',@_);
}
#-> sub CPAN::Bundle::clean ;
sub clean   { shift->rematein('clean',@_); }

#-> sub CPAN::Bundle::uptodate ;
sub uptodate {
    my($self) = @_;
    return 0 unless $self->SUPER::uptodate; # we mut have the current Bundle def
    my $c;
    foreach $c ($self->contains) {
        my $obj = CPAN::Shell->expandany($c);
        return 0 unless $obj->uptodate;
    }
    return 1;
}

#-> sub CPAN::Bundle::readme ;
sub readme  {
    my($self) = @_;
    my($file) = $self->cpan_file or $CPAN::Frontend->myprint(qq{
No File found for bundle } . $self->id . qq{\n}), return;
    $self->debug("self[$self] file[$file]") if $CPAN::DEBUG;
    $CPAN::META->instance('CPAN::Distribution',$file)->readme;
}

package CPAN::Module;
use strict;

# Accessors
#-> sub CPAN::Module::userid
sub userid {
    my $self = shift;
    my $ro = $self->ro;
    return unless $ro;
    return $ro->{userid} || $ro->{CPAN_USERID};
}
#-> sub CPAN::Module::description
sub description {
    my $self = shift;
    my $ro = $self->ro or return "";
    $ro->{description}
}

#-> sub CPAN::Module::distribution
sub distribution {
    my($self) = @_;
    CPAN::Shell->expand("Distribution",$self->cpan_file);
}

#-> sub CPAN::Module::_is_representative_module
sub _is_representative_module {
    my($self) = @_;
    return $self->{_is_representative_module} if defined $self->{_is_representative_module};
    my $pm = $self->cpan_file or return $self->{_is_representative_module} = 0;
    $pm =~ s|.+/||;
    $pm =~ s{\.(?:tar\.(bz2|gz|Z)|t(?:gz|bz)|zip)$}{}i; # see base_id
    $pm =~ s|-\d+\.\d+.+$||;
    $pm =~ s|-[\d\.]+$||;
    $pm =~ s/-/::/g;
    $self->{_is_representative_module} = $pm eq $self->{ID} ? 1 : 0;
    # warn "DEBUG: $pm eq $self->{ID} => $self->{_is_representative_module}";
    $self->{_is_representative_module};
}

#-> sub CPAN::Module::undelay
sub undelay {
    my $self = shift;
    delete $self->{later};
    if ( my $dist = CPAN::Shell->expand("Distribution", $self->cpan_file) ) {
        $dist->undelay;
    }
}

# mark as dirty/clean
#-> sub CPAN::Module::color_cmd_tmps ;
sub color_cmd_tmps {
    my($self) = shift;
    my($depth) = shift || 0;
    my($color) = shift || 0;
    my($ancestors) = shift || [];
    # a module needs to recurse to its cpan_file

    return if exists $self->{incommandcolor}
        && $color==1
        && $self->{incommandcolor}==$color;
    return if $color==0 && !$self->{incommandcolor};
    if ($color>=1) {
        if ( $self->uptodate ) {
            $self->{incommandcolor} = $color;
            return;
        } elsif (my $have_version = $self->available_version) {
            # maybe what we have is good enough
            if (@$ancestors) {
                my $who_asked_for_me = $ancestors->[-1];
                my $obj = CPAN::Shell->expandany($who_asked_for_me);
                if (0) {
                } elsif ($obj->isa("CPAN::Bundle")) {
                    # bundles cannot specify a minimum version
                    return;
                } elsif ($obj->isa("CPAN::Distribution")) {
                    if (my $prereq_pm = $obj->prereq_pm) {
                        for my $k (keys %$prereq_pm) {
                            if (my $want_version = $prereq_pm->{$k}{$self->id}) {
                                if (CPAN::Version->vcmp($have_version,$want_version) >= 0) {
                                    $self->{incommandcolor} = $color;
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        $self->{incommandcolor} = $color; # set me before recursion,
                                          # so we can break it
    }
    if ($depth>=$CPAN::MAX_RECURSION) {
        die(CPAN::Exception::RecursiveDependency->new($ancestors));
    }
    # warn "color_cmd_tmps $depth $color " . $self->id; # sleep 1;

    if ( my $dist = CPAN::Shell->expand("Distribution", $self->cpan_file) ) {
        $dist->color_cmd_tmps($depth+1,$color,[@$ancestors, $self->id]);
    }
    # unreached code?
    # if ($color==0) {
    #    delete $self->{badtestcnt};
    # }
    $self->{incommandcolor} = $color;
}

#-> sub CPAN::Module::as_glimpse ;
sub as_glimpse {
    my($self) = @_;
    my(@m);
    my $class = ref($self);
    $class =~ s/^CPAN:://;
    my $color_on = "";
    my $color_off = "";
    if (
        $CPAN::Shell::COLOR_REGISTERED
        &&
        $CPAN::META->has_inst("Term::ANSIColor")
        &&
        $self->description
       ) {
        $color_on = Term::ANSIColor::color("green");
        $color_off = Term::ANSIColor::color("reset");
    }
    my $uptodateness = " ";
    unless ($class eq "Bundle") {
        my $u = $self->uptodate;
        $uptodateness = $u ? "=" : "<" if defined $u;
    };
    my $id = do {
        my $d = $self->distribution;
        $d ? $d -> pretty_id : $self->cpan_userid;
    };
    push @m, sprintf("%-7s %1s %s%-22s%s (%s)\n",
                     $class,
                     $uptodateness,
                     $color_on,
                     $self->id,
                     $color_off,
                     $id,
                    );
    join "", @m;
}

#-> sub CPAN::Module::dslip_status
sub dslip_status {
    my($self) = @_;
    my($stat);
    # development status
    @{$stat->{D}}{qw,i c a b R M S,}     = qw,idea
                                              pre-alpha alpha beta released
                                              mature standard,;
    # support level
    @{$stat->{S}}{qw,m d u n a,}         = qw,mailing-list
                                              developer comp.lang.perl.*
                                              none abandoned,;
    # language
    @{$stat->{L}}{qw,p c + o h,}         = qw,perl C C++ other hybrid,;
    # interface
    @{$stat->{I}}{qw,f r O p h n,}       = qw,functions
                                              references+ties
                                              object-oriented pragma
                                              hybrid none,;
    # public licence
    @{$stat->{P}}{qw,p g l b a 2 o d r n,} = qw,Standard-Perl
                                              GPL LGPL
                                              BSD Artistic Artistic_2
                                              open-source
                                              distribution_allowed
                                              restricted_distribution
                                              no_licence,;
    for my $x (qw(d s l i p)) {
        $stat->{$x}{' '} = 'unknown';
        $stat->{$x}{'?'} = 'unknown';
    }
    my $ro = $self->ro;
    return +{} unless $ro && $ro->{statd};
    return {
            D  => $ro->{statd},
            S  => $ro->{stats},
            L  => $ro->{statl},
            I  => $ro->{stati},
            P  => $ro->{statp},
            DV => $stat->{D}{$ro->{statd}},
            SV => $stat->{S}{$ro->{stats}},
            LV => $stat->{L}{$ro->{statl}},
            IV => $stat->{I}{$ro->{stati}},
            PV => $stat->{P}{$ro->{statp}},
           };
}

#-> sub CPAN::Module::as_string ;
sub as_string {
    my($self) = @_;
    my(@m);
    CPAN->debug("$self entering as_string") if $CPAN::DEBUG;
    my $class = ref($self);
    $class =~ s/^CPAN:://;
    local($^W) = 0;
    push @m, $class, " id = $self->{ID}\n";
    my $sprintf = "    %-12s %s\n";
    push @m, sprintf($sprintf, 'DESCRIPTION', $self->description)
        if $self->description;
    my $sprintf2 = "    %-12s %s (%s)\n";
    my($userid);
    $userid = $self->userid;
    if ( $userid ) {
        my $author;
        if ($author = CPAN::Shell->expand('Author',$userid)) {
            my $email = "";
            my $m; # old perls
            if ($m = $author->email) {
                $email = " <$m>";
            }
            push @m, sprintf(
                             $sprintf2,
                             'CPAN_USERID',
                             $userid,
                             $author->fullname . $email
                            );
        }
    }
    push @m, sprintf($sprintf, 'CPAN_VERSION', $self->cpan_version)
        if $self->cpan_version;
    if (my $cpan_file = $self->cpan_file) {
        push @m, sprintf($sprintf, 'CPAN_FILE', $cpan_file);
        if (my $dist = CPAN::Shell->expand("Distribution",$cpan_file)) {
            my $upload_date = $dist->upload_date;
            if ($upload_date) {
                push @m, sprintf($sprintf, 'UPLOAD_DATE', $upload_date);
            }
        }
    }
    my $sprintf3 = "    %-12s %1s%1s%1s%1s%1s (%s,%s,%s,%s,%s)\n";
    my $dslip = $self->dslip_status;
    push @m, sprintf(
                     $sprintf3,
                     'DSLIP_STATUS',
                     @{$dslip}{qw(D S L I P DV SV LV IV PV)},
                    ) if $dslip->{D};
    my $local_file = $self->inst_file;
    unless ($self->{MANPAGE}) {
        my $manpage;
        if ($local_file) {
            $manpage = $self->manpage_headline($local_file);
        } else {
            # If we have already untarred it, we should look there
            my $dist = $CPAN::META->instance('CPAN::Distribution',
                                             $self->cpan_file);
            # warn "dist[$dist]";
            # mff=manifest file; mfh=manifest handle
            my($mff,$mfh);
            if (
                $dist->{build_dir}
                and
                (-f  ($mff = File::Spec->catfile($dist->{build_dir}, "MANIFEST")))
                and
                $mfh = FileHandle->new($mff)
               ) {
                CPAN->debug("mff[$mff]") if $CPAN::DEBUG;
                my $lfre = $self->id; # local file RE
                $lfre =~ s/::/./g;
                $lfre .= "\\.pm\$";
                my($lfl); # local file file
                local $/ = "\n";
                my(@mflines) = <$mfh>;
                for (@mflines) {
                    s/^\s+//;
                    s/\s.*//s;
                }
                while (length($lfre)>5 and !$lfl) {
                    ($lfl) = grep /$lfre/, @mflines;
                    CPAN->debug("lfl[$lfl]lfre[$lfre]") if $CPAN::DEBUG;
                    $lfre =~ s/.+?\.//;
                }
                $lfl =~ s/\s.*//; # remove comments
                $lfl =~ s/\s+//g; # chomp would maybe be too system-specific
                my $lfl_abs = File::Spec->catfile($dist->{build_dir},$lfl);
                # warn "lfl_abs[$lfl_abs]";
                if (-f $lfl_abs) {
                    $manpage = $self->manpage_headline($lfl_abs);
                }
            }
        }
        $self->{MANPAGE} = $manpage if $manpage;
    }
    my($item);
    for $item (qw/MANPAGE/) {
        push @m, sprintf($sprintf, $item, $self->{$item})
            if exists $self->{$item};
    }
    for $item (qw/CONTAINS/) {
        push @m, sprintf($sprintf, $item, join(" ",@{$self->{$item}}))
            if exists $self->{$item} && @{$self->{$item}};
    }
    push @m, sprintf($sprintf, 'INST_FILE',
                     $local_file || "(not installed)");
    push @m, sprintf($sprintf, 'INST_VERSION',
                     $self->inst_version) if $local_file;
    if (%{$CPAN::META->{is_tested}||{}}) { # XXX needs to be methodified somehow
        my $available_file = $self->available_file;
        if ($available_file && $available_file ne $local_file) {
            push @m, sprintf($sprintf, 'AVAILABLE_FILE', $available_file);
            push @m, sprintf($sprintf, 'AVAILABLE_VERSION', $self->available_version);
        }
    }
    join "", @m, "\n";
}

#-> sub CPAN::Module::manpage_headline
sub manpage_headline {
    my($self,$local_file) = @_;
    my(@local_file) = $local_file;
    $local_file =~ s/\.pm(?!\n)\Z/.pod/;
    push @local_file, $local_file;
    my(@result,$locf);
    for $locf (@local_file) {
        next unless -f $locf;
        my $fh = FileHandle->new($locf)
            or $Carp::Frontend->mydie("Couldn't open $locf: $!");
        my $inpod = 0;
        local $/ = "\n";
        while (<$fh>) {
            $inpod = m/^=(?!head1\s+NAME\s*$)/ ? 0 :
                m/^=head1\s+NAME\s*$/ ? 1 : $inpod;
            next unless $inpod;
            next if /^=/;
            next if /^\s+$/;
            chomp;
            push @result, $_;
        }
        close $fh;
        last if @result;
    }
    for (@result) {
        s/^\s+//;
        s/\s+$//;
    }
    join " ", @result;
}

#-> sub CPAN::Module::cpan_file ;
# Note: also inherited by CPAN::Bundle
sub cpan_file {
    my $self = shift;
    # CPAN->debug(sprintf "id[%s]", $self->id) if $CPAN::DEBUG;
    unless ($self->ro) {
        CPAN::Index->reload;
    }
    my $ro = $self->ro;
    if ($ro && defined $ro->{CPAN_FILE}) {
        return $ro->{CPAN_FILE};
    } else {
        my $userid = $self->userid;
        if ( $userid ) {
            if ($CPAN::META->exists("CPAN::Author",$userid)) {
                my $author = $CPAN::META->instance("CPAN::Author",
                                                   $userid);
                my $fullname = $author->fullname;
                my $email = $author->email;
                unless (defined $fullname && defined $email) {
                    return sprintf("Contact Author %s",
                                   $userid,
                                  );
                }
                return "Contact Author $fullname <$email>";
            } else {
                return "Contact Author $userid (Email address not available)";
            }
        } else {
            return "N/A";
        }
    }
}

#-> sub CPAN::Module::cpan_version ;
sub cpan_version {
    my $self = shift;

    my $ro = $self->ro;
    unless ($ro) {
        # Can happen with modules that are not on CPAN
        $ro = {};
    }
    $ro->{CPAN_VERSION} = 'undef'
        unless defined $ro->{CPAN_VERSION};
    $ro->{CPAN_VERSION};
}

#-> sub CPAN::Module::force ;
sub force {
    my($self) = @_;
    $self->{force_update} = 1;
}

#-> sub CPAN::Module::fforce ;
sub fforce {
    my($self) = @_;
    $self->{force_update} = 2;
}

#-> sub CPAN::Module::notest ;
sub notest {
    my($self) = @_;
    # $CPAN::Frontend->mywarn("XDEBUG: set notest for Module");
    $self->{notest}++;
}

#-> sub CPAN::Module::rematein ;
sub rematein {
    my($self,$meth) = @_;
    $CPAN::Frontend->myprint(sprintf("Running %s for module '%s'\n",
                                     $meth,
                                     $self->id));
    my $cpan_file = $self->cpan_file;
    if ($cpan_file eq "N/A" || $cpan_file =~ /^Contact Author/) {
        $CPAN::Frontend->mywarn(sprintf qq{
  The module %s isn\'t available on CPAN.

  Either the module has not yet been uploaded to CPAN, or it is
  temporary unavailable. Please contact the author to find out
  more about the status. Try 'i %s'.
},
                                $self->id,
                                $self->id,
                               );
        return;
    }
    my $pack = $CPAN::META->instance('CPAN::Distribution',$cpan_file);
    $pack->called_for($self->id);
    if (exists $self->{force_update}) {
        if ($self->{force_update} == 2) {
            $pack->fforce($meth);
        } else {
            $pack->force($meth);
        }
    }
    $pack->notest($meth) if exists $self->{notest} && $self->{notest};

    $pack->{reqtype} ||= "";
    CPAN->debug("dist-reqtype[$pack->{reqtype}]".
                "self-reqtype[$self->{reqtype}]") if $CPAN::DEBUG;
        if ($pack->{reqtype}) {
            if ($pack->{reqtype} eq "b" && $self->{reqtype} =~ /^[rc]$/) {
                $pack->{reqtype} = $self->{reqtype};
                if (
                    exists $pack->{install}
                    &&
                    (
                     UNIVERSAL::can($pack->{install},"failed") ?
                     $pack->{install}->failed :
                     $pack->{install} =~ /^NO/
                    )
                   ) {
                    delete $pack->{install};
                    $CPAN::Frontend->mywarn
                        ("Promoting $pack->{ID} from 'build_requires' to 'requires'");
                }
            }
        } else {
            $pack->{reqtype} = $self->{reqtype};
        }

    my $success = eval {
        $pack->$meth();
    };
    my $err = $@;
    $pack->unforce if $pack->can("unforce") && exists $self->{force_update};
    $pack->unnotest if $pack->can("unnotest") && exists $self->{notest};
    delete $self->{force_update};
    delete $self->{notest};
    if ($err) {
        die $err;
    }
    return $success;
}

#-> sub CPAN::Module::perldoc ;
sub perldoc { shift->rematein('perldoc') }
#-> sub CPAN::Module::readme ;
sub readme  { shift->rematein('readme') }
#-> sub CPAN::Module::look ;
sub look    { shift->rematein('look') }
#-> sub CPAN::Module::cvs_import ;
sub cvs_import { shift->rematein('cvs_import') }
#-> sub CPAN::Module::get ;
sub get     { shift->rematein('get',@_) }
#-> sub CPAN::Module::make ;
sub make    { shift->rematein('make') }
#-> sub CPAN::Module::test ;
sub test   {
    my $self = shift;
    # $self->{badtestcnt} ||= 0;
    $self->rematein('test',@_);
}

#-> sub CPAN::Module::uptodate ;
sub uptodate {
    my ($self) = @_;
    local ($_);
    my $inst = $self->inst_version or return undef;
    my $cpan = $self->cpan_version;
    local ($^W) = 0;
    CPAN::Version->vgt($cpan,$inst) and return 0;
    CPAN->debug(join("",
                     "returning uptodate. inst_file[",
                     $self->inst_file,
                     "cpan[$cpan] inst[$inst]")) if $CPAN::DEBUG;
    return 1;
}

#-> sub CPAN::Module::install ;
sub install {
    my($self) = @_;
    my($doit) = 0;
    if ($self->uptodate
        &&
        not exists $self->{force_update}
       ) {
        $CPAN::Frontend->myprint(sprintf("%s is up to date (%s).\n",
                                         $self->id,
                                         $self->inst_version,
                                        ));
    } else {
        $doit = 1;
    }
    my $ro = $self->ro;
    if ($ro && $ro->{stats} && $ro->{stats} eq "a") {
        $CPAN::Frontend->mywarn(qq{
\n\n\n     ***WARNING***
     The module $self->{ID} has no active maintainer.\n\n\n
});
        $CPAN::Frontend->mysleep(5);
    }
    return $doit ? $self->rematein('install') : 1;
}
#-> sub CPAN::Module::clean ;
sub clean  { shift->rematein('clean') }

#-> sub CPAN::Module::inst_file ;
sub inst_file {
    my($self) = @_;
    $self->_file_in_path([@INC]);
}

#-> sub CPAN::Module::available_file ;
sub available_file {
    my($self) = @_;
    my $sep = $Config::Config{path_sep};
    my $perllib = $ENV{PERL5LIB};
    $perllib = $ENV{PERLLIB} unless defined $perllib;
    my @perllib = split(/$sep/,$perllib) if defined $perllib;
    my @cpan_perl5inc;
    if ($CPAN::Perl5lib_tempfile) {
        my $yaml = CPAN->_yaml_loadfile($CPAN::Perl5lib_tempfile);
        @cpan_perl5inc = @{$yaml->[0]{inc} || []};
    }
    $self->_file_in_path([@cpan_perl5inc,@perllib,@INC]);
}

#-> sub CPAN::Module::file_in_path ;
sub _file_in_path {
    my($self,$path) = @_;
    my($dir,@packpath);
    @packpath = split /::/, $self->{ID};
    $packpath[-1] .= ".pm";
    if (@packpath == 1 && $packpath[0] eq "readline.pm") {
        unshift @packpath, "Term", "ReadLine"; # historical reasons
    }
    foreach $dir (@$path) {
        my $pmfile = File::Spec->catfile($dir,@packpath);
        if (-f $pmfile) {
            return $pmfile;
        }
    }
    return;
}

#-> sub CPAN::Module::xs_file ;
sub xs_file {
    my($self) = @_;
    my($dir,@packpath);
    @packpath = split /::/, $self->{ID};
    push @packpath, $packpath[-1];
    $packpath[-1] .= "." . $Config::Config{'dlext'};
    foreach $dir (@INC) {
        my $xsfile = File::Spec->catfile($dir,'auto',@packpath);
        if (-f $xsfile) {
            return $xsfile;
        }
    }
    return;
}

#-> sub CPAN::Module::inst_version ;
sub inst_version {
    my($self) = @_;
    my $parsefile = $self->inst_file or return;
    my $have = $self->parse_version($parsefile);
    $have;
}

#-> sub CPAN::Module::inst_version ;
sub available_version {
    my($self) = @_;
    my $parsefile = $self->available_file or return;
    my $have = $self->parse_version($parsefile);
    $have;
}

#-> sub CPAN::Module::parse_version ;
sub parse_version {
    my($self,$parsefile) = @_;
    my $have = eval { MM->parse_version($parsefile); };
    if ($@) {
        $CPAN::Frontend->mywarn("Error while parsing version number in file '$parsefile'\n");
    }
    my $leastsanity = eval { defined $have && length $have; };
    $have = "undef" unless $leastsanity;
    $have =~ s/^ //; # since the %vd hack these two lines here are needed
    $have =~ s/ $//; # trailing whitespace happens all the time

    $have = CPAN::Version->readable($have);

    $have =~ s/\s*//g; # stringify to float around floating point issues
    $have; # no stringify needed, \s* above matches always
}

#-> sub CPAN::Module::reports
sub reports {
    my($self) = @_;
    $self->distribution->reports;
}

package CPAN;
use strict;

1;


__END__

=head1 NAME

CPAN - query, download and build perl modules from CPAN sites

=head1 SYNOPSIS

Interactive mode:

  perl -MCPAN -e shell

--or--

  cpan

Basic commands:

  # Modules:

  cpan> install Acme::Meta                       # in the shell

  CPAN::Shell->install("Acme::Meta");            # in perl

  # Distributions:

  cpan> install NWCLARK/Acme-Meta-0.02.tar.gz    # in the shell

  CPAN::Shell->
    install("NWCLARK/Acme-Meta-0.02.tar.gz");    # in perl

  # module objects:

  $mo = CPAN::Shell->expandany($mod);
  $mo = CPAN::Shell->expand("Module",$mod);      # same thing

  # distribution objects:

  $do = CPAN::Shell->expand("Module",$mod)->distribution;
  $do = CPAN::Shell->expandany($distro);         # same thing
  $do = CPAN::Shell->expand("Distribution",
                            $distro);            # same thing

=head1 DESCRIPTION

The CPAN module automates or at least simplifies the make and install
of perl modules and extensions. It includes some primitive searching
capabilities and knows how to use Net::FTP, LWP, and certain external
download clients to fetch distributions from the net.

These are fetched from one or more mirrored CPAN (Comprehensive
Perl Archive Network) sites and unpacked in a dedicated directory.

The CPAN module also supports named and versioned
I<bundles> of modules. Bundles simplify handling of sets of
related modules. See Bundles below.

The package contains a session manager and a cache manager. The
session manager keeps track of what has been fetched, built, and
installed in the current session. The cache manager keeps track of the
disk space occupied by the make processes and deletes excess space
using a simple FIFO mechanism.

All methods provided are accessible in a programmer style and in an
interactive shell style.

=head2 CPAN::shell([$prompt, $command]) Starting Interactive Mode

Enter interactive mode by running

    perl -MCPAN -e shell

or

    cpan

which puts you into a readline interface. If C<Term::ReadKey> and
either of C<Term::ReadLine::Perl> or C<Term::ReadLine::Gnu> are installed,
history and command completion are supported.

Once at the command line, type C<h> for one-page help
screen; the rest should be self-explanatory.

The function call C<shell> takes two optional arguments: one the
prompt, the second the default initial command line (the latter
only works if a real ReadLine interface module is installed).

The most common uses of the interactive modes are

=over 2

=item Searching for authors, bundles, distribution files and modules

There are corresponding one-letter commands C<a>, C<b>, C<d>, and C<m>
for each of the four categories and another, C<i> for any of the
mentioned four. Each of the four entities is implemented as a class
with slightly differing methods for displaying an object.

Arguments to these commands are either strings exactly matching
the identification string of an object, or regular expressions 
matched case-insensitively against various attributes of the
objects. The parser only recognizes a regular expression when you
enclose it with slashes.

The principle is that the number of objects found influences how an
item is displayed. If the search finds one item, the result is
displayed with the rather verbose method C<as_string>, but if 
more than one is found, each object is displayed with the terse method
C<as_glimpse>.

Examples:

  cpan> m Acme::MetaSyntactic
  Module id = Acme::MetaSyntactic
      CPAN_USERID  BOOK (Philippe Bruhat (BooK) <[...]>)
      CPAN_VERSION 0.99
      CPAN_FILE    B/BO/BOOK/Acme-MetaSyntactic-0.99.tar.gz
      UPLOAD_DATE  2006-11-06
      MANPAGE      Acme::MetaSyntactic - Themed metasyntactic variables names
      INST_FILE    /usr/local/lib/perl/5.10.0/Acme/MetaSyntactic.pm
      INST_VERSION 0.99
  cpan> a BOOK
  Author id = BOOK
      EMAIL        [...]
      FULLNAME     Philippe Bruhat (BooK)
  cpan> d BOOK/Acme-MetaSyntactic-0.99.tar.gz
  Distribution id = B/BO/BOOK/Acme-MetaSyntactic-0.99.tar.gz
      CPAN_USERID  BOOK (Philippe Bruhat (BooK) <[...]>)
      CONTAINSMODS Acme::MetaSyntactic Acme::MetaSyntactic::Alias [...]
      UPLOAD_DATE  2006-11-06
  cpan> m /lorem/
  Module  = Acme::MetaSyntactic::loremipsum (BOOK/Acme-MetaSyntactic-0.99.tar.gz)
  Module    Text::Lorem            (ADEOLA/Text-Lorem-0.3.tar.gz)
  Module    Text::Lorem::More      (RKRIMEN/Text-Lorem-More-0.12.tar.gz)
  Module    Text::Lorem::More::Source (RKRIMEN/Text-Lorem-More-0.12.tar.gz)
  cpan> i /berlin/
  Distribution    BEATNIK/Filter-NumberLines-0.02.tar.gz
  Module  = DateTime::TimeZone::Europe::Berlin (DROLSKY/DateTime-TimeZone-0.7904.tar.gz)
  Module    Filter::NumberLines    (BEATNIK/Filter-NumberLines-0.02.tar.gz)
  Author          [...]

The examples illustrate several aspects: the first three queries
target modules, authors, or distros directly and yield exactly one
result. The last two use regular expressions and yield several
results. The last one targets all of bundles, modules, authors, and
distros simultaneously. When more than one result is available, they
are printed in one-line format.

=item C<get>, C<make>, C<test>, C<install>, C<clean> modules or distributions

These commands take any number of arguments and investigate what is
necessary to perform the action. If the argument is a distribution
file name (recognized by embedded slashes), it is processed. If it is
a module, CPAN determines the distribution file in which this module
is included and processes that, following any dependencies named in
the module's META.yml or Makefile.PL (this behavior is controlled by
the configuration parameter C<prerequisites_policy>.)

C<get> downloads a distribution file and untars or unzips it, C<make>
builds it, C<test> runs the test suite, and C<install> installs it.

Any C<make> or C<test> is run unconditionally. An

  install <distribution_file>

is also run unconditionally. But for

  install <module>

CPAN checks whether an install is needed and prints
I<module up to date> if the distribution file containing
the module doesn't need updating.

CPAN also keeps track of what it has done within the current session
and doesn't try to build a package a second time regardless of whether it
succeeded or not. It does not repeat a test run if the test
has been run successfully before. Same for install runs.

The C<force> pragma may precede another command (currently: C<get>,
C<make>, C<test>, or C<install>) to execute the command from scratch
and attempt to continue past certain errors. See the section below on
the C<force> and the C<fforce> pragma.

The C<notest> pragma skips the test part in the build
process.

Example:

    cpan> notest install Tk

A C<clean> command results in a

  make clean

being executed within the distribution file's working directory.

=item C<readme>, C<perldoc>, C<look> module or distribution

C<readme> displays the README file of the associated distribution.
C<Look> gets and untars (if not yet done) the distribution file,
changes to the appropriate directory and opens a subshell process in
that directory. C<perldoc> displays the module's pod documentation 
in html or plain text format.

=item C<ls> author

=item C<ls> globbing_expression

The first form lists all distribution files in and below an author's
CPAN directory as stored in the CHECKUMS files distributed on
CPAN. The listing recurses into subdirectories.

The second form limits or expands the output with shell
globbing as in the following examples:

      ls JV/make*
      ls GSAR/*make*
      ls */*make*

The last example is very slow and outputs extra progress indicators
that break the alignment of the result.

Note that globbing only lists directories explicitly asked for, for
example FOO/* will not list FOO/bar/Acme-Sthg-n.nn.tar.gz. This may be
regarded as a bug that may be changed in some future version.

=item C<failed>

The C<failed> command reports all distributions that failed on one of
C<make>, C<test> or C<install> for some reason in the currently
running shell session.

=item Persistence between sessions

If the C<YAML> or the C<YAML::Syck> module is installed a record of
the internal state of all modules is written to disk after each step.
The files contain a signature of the currently running perl version
for later perusal.

If the configurations variable C<build_dir_reuse> is set to a true
value, then CPAN.pm reads the collected YAML files. If the stored
signature matches the currently running perl, the stored state is
loaded into memory such that persistence between sessions
is effectively established.

=item The C<force> and the C<fforce> pragma

To speed things up in complex installation scenarios, CPAN.pm keeps
track of what it has already done and refuses to do some things a
second time. A C<get>, a C<make>, and an C<install> are not repeated.
A C<test> is repeated only if the previous test was unsuccessful. The
diagnostic message when CPAN.pm refuses to do something a second time
is one of I<Has already been >C<unwrapped|made|tested successfully> or
something similar. Another situation where CPAN refuses to act is an
C<install> if the corresponding C<test> was not successful.

In all these cases, the user can override this stubborn behaviour by
prepending the command with the word force, for example:

  cpan> force get Foo
  cpan> force make AUTHOR/Bar-3.14.tar.gz
  cpan> force test Baz
  cpan> force install Acme::Meta

Each I<forced> command is executed with the corresponding part of its
memory erased.

The C<fforce> pragma is a variant that emulates a C<force get> which
erases the entire memory followed by the action specified, effectively
restarting the whole get/make/test/install procedure from scratch.

=item Lockfile

Interactive sessions maintain a lockfile, by default C<~/.cpan/.lock>.
Batch jobs can run without a lockfile and not disturb each other.

The shell offers to run in I<downgraded mode> when another process is
holding the lockfile. This is an experimental feature that is not yet
tested very well. This second shell then does not write the history
file, does not use the metadata file, and has a different prompt.

=item Signals

CPAN.pm installs signal handlers for SIGINT and SIGTERM. While you are
in the cpan-shell, it is intended that you can press C<^C> anytime and
return to the cpan-shell prompt. A SIGTERM will cause the cpan-shell
to clean up and leave the shell loop. You can emulate the effect of a
SIGTERM by sending two consecutive SIGINTs, which usually means by
pressing C<^C> twice.

CPAN.pm ignores SIGPIPE. If the user sets C<inactivity_timeout>, a
SIGALRM is used during the run of the C<perl Makefile.PL> or C<perl
Build.PL> subprocess.

=back

=head2 CPAN::Shell

The commands available in the shell interface are methods in
the package CPAN::Shell. If you enter the shell command, your
input is split by the Text::ParseWords::shellwords() routine, which
acts like most shells do. The first word is interpreted as the
method to be invoked, and the rest of the words are treated as the method's arguments.
Continuation lines are supported by ending a line with a
literal backslash.

=head2 autobundle

C<autobundle> writes a bundle file into the
C<$CPAN::Config-E<gt>{cpan_home}/Bundle> directory. The file contains
a list of all modules that are both available from CPAN and currently
installed within @INC. The name of the bundle file is based on the
current date and a counter.

=head2 hosts

Note: this feature is still in alpha state and may change in future
versions of CPAN.pm

This commands provides a statistical overview over recent download
activities. The data for this is collected in the YAML file
C<FTPstats.yml> in your C<cpan_home> directory. If no YAML module is
configured or YAML not installed, no stats are provided.

=head2 mkmyconfig

mkmyconfig() writes your own CPAN::MyConfig file into your C<~/.cpan/>
directory so that you can save your own preferences instead of the
system-wide ones.

=head2 recent ***EXPERIMENTAL COMMAND***

The C<recent> command downloads a list of recent uploads to CPAN and
displays them I<slowly>. While the command is running, a $SIG{INT} 
exits the loop after displaying the current item.

B<Note>: This command requires XML::LibXML installed.

B<Note>: This whole command currently is just a hack and will
probably change in future versions of CPAN.pm, but the general
approach will likely remain.

B<Note>: See also L<smoke>

=head2 recompile

recompile() is a special command that takes no argument and
runs the make/test/install cycle with brute force over all installed
dynamically loadable extensions (aka XS modules) with 'force' in
effect. The primary purpose of this command is to finish a network
installation. Imagine you have a common source tree for two different
architectures. You decide to do a completely independent fresh
installation. You start on one architecture with the help of a Bundle
file produced earlier. CPAN installs the whole Bundle for you, but
when you try to repeat the job on the second architecture, CPAN
responds with a C<"Foo up to date"> message for all modules. So you
invoke CPAN's recompile on the second architecture and you're done.

Another popular use for C<recompile> is to act as a rescue in case your
perl breaks binary compatibility. If one of the modules that CPAN uses
is in turn depending on binary compatibility (so you cannot run CPAN
commands), then you should try the CPAN::Nox module for recovery.

=head2 report Bundle|Distribution|Module

The C<report> command temporarily turns on the C<test_report> config
variable, then runs the C<force test> command with the given
arguments. The C<force> pragma reruns the tests and repeats
every step that might have failed before.

=head2 smoke ***EXPERIMENTAL COMMAND***

B<*** WARNING: this command downloads and executes software from CPAN to
your computer of completely unknown status. You should never do
this with your normal account and better have a dedicated well
separated and secured machine to do this. ***>

The C<smoke> command takes the list of recent uploads to CPAN as
provided by the C<recent> command and tests them all. While the
command is running $SIG{INT} is defined to mean that the current item
shall be skipped.

B<Note>: This whole command currently is just a hack and will
probably change in future versions of CPAN.pm, but the general
approach will likely remain.

B<Note>: See also L<recent>

=head2 upgrade [Module|/Regex/]...

The C<upgrade> command first runs an C<r> command with the given
arguments and then installs the newest versions of all modules that
were listed by that.

=head2 The four C<CPAN::*> Classes: Author, Bundle, Module, Distribution

Although it may be considered internal, the class hierarchy does matter
for both users and programmer. CPAN.pm deals with the four
classes mentioned above, and those classes all share a set of methods. Classical
single polymorphism is in effect. A metaclass object registers all
objects of all kinds and indexes them with a string. The strings
referencing objects have a separated namespace (well, not completely
separated):

         Namespace                         Class

   words containing a "/" (slash)      Distribution
    words starting with Bundle::          Bundle
          everything else            Module or Author

Modules know their associated Distribution objects. They always refer
to the most recent official release. Developers may mark their releases
as unstable development versions (by inserting an underbar into the
module version number which will also be reflected in the distribution
name when you run 'make dist'), so the really hottest and newest
distribution is not always the default.  If a module Foo circulates
on CPAN in both version 1.23 and 1.23_90, CPAN.pm offers a convenient
way to install version 1.23 by saying

    install Foo

This would install the complete distribution file (say
BAR/Foo-1.23.tar.gz) with all accompanying material. But if you would
like to install version 1.23_90, you need to know where the
distribution file resides on CPAN relative to the authors/id/
directory. If the author is BAR, this might be BAR/Foo-1.23_90.tar.gz;
so you would have to say

    install BAR/Foo-1.23_90.tar.gz

The first example will be driven by an object of the class
CPAN::Module, the second by an object of class CPAN::Distribution.

=head2 Integrating local directories

Note: this feature is still in alpha state and may change in future
versions of CPAN.pm

Distribution objects are normally distributions from the CPAN, but
there is a slightly degenerate case for Distribution objects, too, of
projects held on the local disk. These distribution objects have the
same name as the local directory and end with a dot. A dot by itself
is also allowed for the current directory at the time CPAN.pm was
used. All actions such as C<make>, C<test>, and C<install> are applied
directly to that directory. This gives the command C<cpan .> an
interesting touch: while the normal mantra of installing a CPAN module
without CPAN.pm is one of

    perl Makefile.PL                 perl Build.PL
           ( go and get prerequisites )
    make                             ./Build
    make test                        ./Build test
    make install                     ./Build install

the command C<cpan .> does all of this at once. It figures out which
of the two mantras is appropriate, fetches and installs all
prerequisites, takes care of them recursively, and finally finishes the
installation of the module in the current directory, be it a CPAN
module or not.

The typical usage case is for private modules or working copies of
projects from remote repositories on the local disk.

=head2 Redirection

The usual shell redirection symbols C< | > and C<< > >> are recognized
by the cpan shell B<only when surrounded by whitespace>. So piping to
pager or redirecting output into a file works somewhat as in a normal
shell, with the stipulation that you must type extra spaces.

=head1 CONFIGURATION

When the CPAN module is used for the first time, a configuration
dialogue tries to determine a couple of site specific options. The
result of the dialog is stored in a hash reference C< $CPAN::Config >
in a file CPAN/Config.pm.

Default values defined in the CPAN/Config.pm file can be
overridden in a user specific file: CPAN/MyConfig.pm. Such a file is
best placed in C<$HOME/.cpan/CPAN/MyConfig.pm>, because C<$HOME/.cpan> is
added to the search path of the CPAN module before the use() or
require() statements. The mkmyconfig command writes this file for you.

The C<o conf> command has various bells and whistles:

=over

=item completion support

If you have a ReadLine module installed, you can hit TAB at any point
of the commandline and C<o conf> will offer you completion for the
built-in subcommands and/or config variable names.

=item displaying some help: o conf help

Displays a short help

=item displaying current values: o conf [KEY]

Displays the current value(s) for this config variable. Without KEY,
displays all subcommands and config variables.

Example:

  o conf shell

If KEY starts and ends with a slash, the string in between is
treated as a regular expression and only keys matching this regex
are displayed

Example:

  o conf /color/

=item changing of scalar values: o conf KEY VALUE

Sets the config variable KEY to VALUE. The empty string can be
specified as usual in shells, with C<''> or C<"">

Example:

  o conf wget /usr/bin/wget

=item changing of list values: o conf KEY SHIFT|UNSHIFT|PUSH|POP|SPLICE|LIST

If a config variable name ends with C<list>, it is a list. C<o conf
KEY shift> removes the first element of the list, C<o conf KEY pop>
removes the last element of the list. C<o conf KEYS unshift LIST>
prepends a list of values to the list, C<o conf KEYS push LIST>
appends a list of valued to the list.

Likewise, C<o conf KEY splice LIST> passes the LIST to the corresponding
splice command.

Finally, any other list of arguments is taken as a new list value for
the KEY variable discarding the previous value.

Examples:

  o conf urllist unshift http://cpan.dev.local/CPAN
  o conf urllist splice 3 1
  o conf urllist http://cpan1.local http://cpan2.local ftp://ftp.perl.org

=item reverting to saved: o conf defaults

Reverts all config variables to the state in the saved config file.

=item saving the config: o conf commit

Saves all config variables to the current config file (CPAN/Config.pm
or CPAN/MyConfig.pm that was loaded at start).

=back

The configuration dialog can be started any time later again by
issuing the command C< o conf init > in the CPAN shell. A subset of
the configuration dialog can be run by issuing C<o conf init WORD>
where WORD is any valid config variable or a regular expression.

=head2 Config Variables

The following keys in the hash reference $CPAN::Config are
currently defined:

  applypatch         path to external prg
  auto_commit        commit all changes to config variables to disk
  build_cache        size of cache for directories to build modules
  build_dir          locally accessible directory to build modules
  build_dir_reuse    boolean if distros in build_dir are persistent
  build_requires_install_policy
                     to install or not to install when a module is
                     only needed for building. yes|no|ask/yes|ask/no
  bzip2              path to external prg
  cache_metadata     use serializer to cache metadata
  check_sigs         if signatures should be verified
  colorize_debug     Term::ANSIColor attributes for debugging output
  colorize_output    boolean if Term::ANSIColor should colorize output
  colorize_print     Term::ANSIColor attributes for normal output
  colorize_warn      Term::ANSIColor attributes for warnings
  commandnumber_in_prompt
                     boolean if you want to see current command number
  commands_quote     preferred character to use for quoting external
                     commands when running them. Defaults to double
                     quote on Windows, single tick everywhere else;
                     can be set to space to disable quoting
  connect_to_internet_ok
                     whether to ask if opening a connection is ok before
                     urllist is specified
  cpan_home          local directory reserved for this package
  curl               path to external prg
  dontload_hash      DEPRECATED
  dontload_list      arrayref: modules in the list will not be
                     loaded by the CPAN::has_inst() routine
  ftp                path to external prg
  ftp_passive        if set, the envariable FTP_PASSIVE is set for downloads
  ftp_proxy          proxy host for ftp requests
  ftpstats_period    max number of days to keep download statistics
  ftpstats_size      max number of items to keep in the download statistics
  getcwd             see below
  gpg                path to external prg
  gzip               location of external program gzip
  halt_on_failure    stop processing after the first failure of queued
                     items or dependencies
  histfile           file to maintain history between sessions
  histsize           maximum number of lines to keep in histfile
  http_proxy         proxy host for http requests
  inactivity_timeout breaks interactive Makefile.PLs or Build.PLs
                     after this many seconds inactivity. Set to 0 to
                     disable timeouts.
  index_expire       refetch index files after this many days 
  inhibit_startup_message
                     if true, suppress the startup message
  keep_source_where  directory in which to keep the source (if we do)
  load_module_verbosity
                     report loading of optional modules used by CPAN.pm
  lynx               path to external prg
  make               location of external make program
  make_arg           arguments that should always be passed to 'make'
  make_install_make_command
                     the make command for running 'make install', for
                     example 'sudo make'
  make_install_arg   same as make_arg for 'make install'
  makepl_arg         arguments passed to 'perl Makefile.PL'
  mbuild_arg         arguments passed to './Build'
  mbuild_install_arg arguments passed to './Build install'
  mbuild_install_build_command
                     command to use instead of './Build' when we are
                     in the install stage, for example 'sudo ./Build'
  mbuildpl_arg       arguments passed to 'perl Build.PL'
  ncftp              path to external prg
  ncftpget           path to external prg
  no_proxy           don't proxy to these hosts/domains (comma separated list)
  pager              location of external program more (or any pager)
  password           your password if you CPAN server wants one
  patch              path to external prg
  patches_dir        local directory containing patch files
  perl5lib_verbosity verbosity level for PERL5LIB additions
  prefer_installer   legal values are MB and EUMM: if a module comes
                     with both a Makefile.PL and a Build.PL, use the
                     former (EUMM) or the latter (MB); if the module
                     comes with only one of the two, that one will be
                     used no matter the setting
  prerequisites_policy
                     what to do if you are missing module prerequisites
                     ('follow' automatically, 'ask' me, or 'ignore')
  prefs_dir          local directory to store per-distro build options
  proxy_user         username for accessing an authenticating proxy
  proxy_pass         password for accessing an authenticating proxy
  randomize_urllist  add some randomness to the sequence of the urllist
  scan_cache         controls scanning of cache ('atstart' or 'never')
  shell              your favorite shell
  show_unparsable_versions
                     boolean if r command tells which modules are versionless
  show_upload_date   boolean if commands should try to determine upload date
  show_zero_versions boolean if r command tells for which modules $version==0
  tar                location of external program tar
  tar_verbosity      verbosity level for the tar command
  term_is_latin      deprecated: if true Unicode is translated to ISO-8859-1
                     (and nonsense for characters outside latin range)
  term_ornaments     boolean to turn ReadLine ornamenting on/off
  test_report        email test reports (if CPAN::Reporter is installed)
  trust_test_report_history
                     skip testing when previously tested ok (according to
                     CPAN::Reporter history)
  unzip              location of external program unzip
  urllist            arrayref to nearby CPAN sites (or equivalent locations)
  use_sqlite         use CPAN::SQLite for metadata storage (fast and lean)
  username           your username if you CPAN server wants one
  wait_list          arrayref to a wait server to try (See CPAN::WAIT)
  wget               path to external prg
  yaml_load_code     enable YAML code deserialisation via CPAN::DeferredCode
  yaml_module        which module to use to read/write YAML files

You can set and query each of these options interactively in the cpan
shell with the C<o conf> or the C<o conf init> command as specified below.

=over 2

=item C<o conf E<lt>scalar optionE<gt>>

prints the current value of the I<scalar option>

=item C<o conf E<lt>scalar optionE<gt> E<lt>valueE<gt>>

Sets the value of the I<scalar option> to I<value>

=item C<o conf E<lt>list optionE<gt>>

prints the current value of the I<list option> in MakeMaker's
neatvalue format.

=item C<o conf E<lt>list optionE<gt> [shift|pop]>

shifts or pops the array in the I<list option> variable

=item C<o conf E<lt>list optionE<gt> [unshift|push|splice] E<lt>listE<gt>>

works like the corresponding perl commands.

=item interactive editing: o conf init [MATCH|LIST]

Runs an interactive configuration dialog for matching variables.
Without argument runs the dialog over all supported config variables.
To specify a MATCH the argument must be enclosed by slashes.

Examples:

  o conf init ftp_passive ftp_proxy
  o conf init /color/

Note: this method of setting config variables often provides more
explanation about the functioning of a variable than the manpage.

=back

=head2 CPAN::anycwd($path): Note on config variable getcwd

CPAN.pm changes the current working directory often and needs to
determine its own current working directory. By default it uses
Cwd::cwd, but if for some reason this doesn't work on your system,
configure alternatives according to the following table:

=over 4

=item cwd

Calls Cwd::cwd

=item getcwd

Calls Cwd::getcwd

=item fastcwd

Calls Cwd::fastcwd

=item backtickcwd

Calls the external command cwd.

=back

=head2 Note on the format of the urllist parameter

urllist parameters are URLs according to RFC 1738. We do a little
guessing if your URL is not compliant, but if you have problems with
C<file> URLs, please try the correct format. Either:

    file://localhost/whatever/ftp/pub/CPAN/

or

    file:///home/ftp/pub/CPAN/

=head2 The urllist parameter has CD-ROM support

The C<urllist> parameter of the configuration table contains a list of
URLs used for downloading. If the list contains any
C<file> URLs, CPAN always tries there first. This
feature is disabled for index files. So the recommendation for the
owner of a CD-ROM with CPAN contents is: include your local, possibly
outdated CD-ROM as a C<file> URL at the end of urllist, e.g.

  o conf urllist push file://localhost/CDROM/CPAN

CPAN.pm will then fetch the index files from one of the CPAN sites
that come at the beginning of urllist. It will later check for each
module to see whether there is a local copy of the most recent version.

Another peculiarity of urllist is that the site that we could
successfully fetch the last file from automatically gets a preference
token and is tried as the first site for the next request. So if you
add a new site at runtime it may happen that the previously preferred
site will be tried another time. This means that if you want to disallow
a site for the next transfer, it must be explicitly removed from
urllist.

=head2 Maintaining the urllist parameter

If you have YAML.pm (or some other YAML module configured in
C<yaml_module>) installed, CPAN.pm collects a few statistical data
about recent downloads. You can view the statistics with the C<hosts>
command or inspect them directly by looking into the C<FTPstats.yml>
file in your C<cpan_home> directory.

To get some interesting statistics, it is recommended that
C<randomize_urllist> be set; this introduces some amount of
randomness into the URL selection.

=head2 The C<requires> and C<build_requires> dependency declarations

Since CPAN.pm version 1.88_51 modules declared as C<build_requires> by
a distribution are treated differently depending on the config
variable C<build_requires_install_policy>. By setting
C<build_requires_install_policy> to C<no>, such a module is not 
installed. It is only built and tested, and then kept in the list of
tested but uninstalled modules. As such, it is available during the
build of the dependent module by integrating the path to the
C<blib/arch> and C<blib/lib> directories in the environment variable
PERL5LIB. If C<build_requires_install_policy> is set ti C<yes>, then
both modules declared as C<requires> and those declared as
C<build_requires> are treated alike. By setting to C<ask/yes> or
C<ask/no>, CPAN.pm asks the user and sets the default accordingly.

=head2 Configuration for individual distributions (I<Distroprefs>)

(B<Note:> This feature has been introduced in CPAN.pm 1.8854 and is
still considered beta quality)

Distributions on CPAN usually behave according to what we call the
CPAN mantra. Or since the event of Module::Build, we should talk about
two mantras:

    perl Makefile.PL     perl Build.PL
    make                 ./Build
    make test            ./Build test
    make install         ./Build install

But some modules cannot be built with this mantra. They try to get
some extra data from the user via the environment, extra arguments, or
interactively--thus disturbing the installation of large bundles like
Phalanx100 or modules with many dependencies like Plagger.

The distroprefs system of C<CPAN.pm> addresses this problem by
allowing the user to specify extra informations and recipes in YAML
files to either

=over

=item

pass additional arguments to one of the four commands,

=item

set environment variables

=item

instantiate an Expect object that reads from the console, waits for
some regular expressions and enters some answers

=item

temporarily override assorted C<CPAN.pm> configuration variables

=item

specify dependencies the original maintainer forgot 

=item

disable the installation of an object altogether

=back

See the YAML and Data::Dumper files that come with the C<CPAN.pm>
distribution in the C<distroprefs/> directory for examples.

=head2 Filenames

The YAML files themselves must have the C<.yml> extension; all other
files are ignored (for two exceptions see I<Fallback Data::Dumper and
Storable> below). The containing directory can be specified in
C<CPAN.pm> in the C<prefs_dir> config variable. Try C<o conf init
prefs_dir> in the CPAN shell to set and activate the distroprefs
system.

Every YAML file may contain arbitrary documents according to the YAML
specification, and every document is treated as an entity that
can specify the treatment of a single distribution.

Filenames can be picked arbitrarily; C<CPAN.pm> always reads
all files (in alphabetical order) and takes the key C<match> (see
below in I<Language Specs>) as a hashref containing match criteria
that determine if the current distribution matches the YAML document
or not.

=head2 Fallback Data::Dumper and Storable

If neither your configured C<yaml_module> nor YAML.pm is installed,
CPAN.pm falls back to using Data::Dumper and Storable and looks for
files with the extensions C<.dd> or C<.st> in the C<prefs_dir>
directory. These files are expected to contain one or more hashrefs.
For Data::Dumper generated files, this is expected to be done with by
defining C<$VAR1>, C<$VAR2>, etc. The YAML shell would produce these
with the command

    ysh < somefile.yml > somefile.dd

For Storable files the rule is that they must be constructed such that
C<Storable::retrieve(file)> returns an array reference and the array
elements represent one distropref object each. The conversion from
YAML would look like so:

    perl -MYAML=LoadFile -MStorable=nstore -e '
        @y=LoadFile(shift);
        nstore(\@y, shift)' somefile.yml somefile.st

In bootstrapping situations it is usually sufficient to translate only
a few YAML files to Data::Dumper for crucial modules like
C<YAML::Syck>, C<YAML.pm> and C<Expect.pm>. If you prefer Storable
over Data::Dumper, remember to pull out a Storable version that writes
an older format than all the other Storable versions that will need to
read them.

=head2 Blueprint

The following example contains all supported keywords and structures
with the exception of C<eexpect> which can be used instead of
C<expect>.

  ---
  comment: "Demo"
  match:
    module: "Dancing::Queen"
    distribution: "^CHACHACHA/Dancing-"
    perl: "/usr/local/cariba-perl/bin/perl"
    perlconfig:
      archname: "freebsd"
    env:
      DANCING_FLOOR: "Shubiduh"
  disabled: 1
  cpanconfig:
    make: gmake
  pl:
    args:
      - "--somearg=specialcase"

    env: {}

    expect:
      - "Which is your favorite fruit"
      - "apple\n"

  make:
    args:
      - all
      - extra-all

    env: {}

    expect: []

    commendline: "echo SKIPPING make"

  test:
    args: []

    env: {}

    expect: []

  install:
    args: []

    env:
      WANT_TO_INSTALL: YES

    expect:
      - "Do you really want to install"
      - "y\n"

  patches:
    - "ABCDE/Fedcba-3.14-ABCDE-01.patch"

  depends:
    configure_requires:
      LWP: 5.8
    build_requires:
      Test::Exception: 0.25
    requires:
      Spiffy: 0.30


=head2 Language Specs

Every YAML document represents a single hash reference. The valid keys
in this hash are as follows:

=over

=item comment [scalar]

A comment

=item cpanconfig [hash]

Temporarily override assorted C<CPAN.pm> configuration variables.

Supported are: C<build_requires_install_policy>, C<check_sigs>,
C<make>, C<make_install_make_command>, C<prefer_installer>,
C<test_report>. Please report as a bug when you need another one
supported.

=item depends [hash] *** EXPERIMENTAL FEATURE ***

All three types, namely C<configure_requires>, C<build_requires>, and
C<requires> are supported in the way specified in the META.yml
specification. The current implementation I<merges> the specified
dependencies with those declared by the package maintainer. In a
future implementation this may be changed to override the original
declaration.

=item disabled [boolean]

Specifies that this distribution shall not be processed at all.

=item features [array] *** EXPERIMENTAL FEATURE ***

Experimental implementation to deal with optional_features from
META.yml. Still needs coordination with installer software and
currently works only for META.yml declaring C<dynamic_config=0>. Use
with caution.

=item goto [string]

The canonical name of a delegate distribution to install
instead. Useful when a new version, although it tests OK itself,
breaks something else or a developer release or a fork is already
uploaded that is better than the last released version.

=item install [hash]

Processing instructions for the C<make install> or C<./Build install>
phase of the CPAN mantra. See below under I<Processing Instructions>.

=item make [hash]

Processing instructions for the C<make> or C<./Build> phase of the
CPAN mantra. See below under I<Processing Instructions>.

=item match [hash]

A hashref with one or more of the keys C<distribution>, C<modules>,
C<perl>, C<perlconfig>, and C<env> that specify whether a document is
targeted at a specific CPAN distribution or installation.

The corresponding values are interpreted as regular expressions. The
C<distribution> related one will be matched against the canonical
distribution name, e.g. "AUTHOR/Foo-Bar-3.14.tar.gz".

The C<module> related one will be matched against I<all> modules
contained in the distribution until one module matches.

The C<perl> related one will be matched against C<$^X> (but with the
absolute path).

The value associated with C<perlconfig> is itself a hashref that is
matched against corresponding values in the C<%Config::Config> hash
living in the C<Config.pm> module.

The value associated with C<env> is itself a hashref that is
matched against corresponding values in the C<%ENV> hash.

If more than one restriction of C<module>, C<distribution>, etc. is
specified, the results of the separately computed match values must
all match. If so, the hashref represented by the
YAML document is returned as the preference structure for the current
distribution.

=item patches [array]

An array of patches on CPAN or on the local disk to be applied in
order via an external patch program. If the value for the C<-p>
parameter is C<0> or C<1> is determined by reading the patch
beforehand.

Note: if the C<applypatch> program is installed and C<CPAN::Config>
knows about it B<and> a patch is written by the C<makepatch> program,
then C<CPAN.pm> lets C<applypatch> apply the patch. Both C<makepatch>
and C<applypatch> are available from CPAN in the C<JV/makepatch-*>
distribution.

=item pl [hash]

Processing instructions for the C<perl Makefile.PL> or C<perl
Build.PL> phase of the CPAN mantra. See below under I<Processing
Instructions>.

=item test [hash]

Processing instructions for the C<make test> or C<./Build test> phase
of the CPAN mantra. See below under I<Processing Instructions>.

=back

=head2 Processing Instructions

=over

=item args [array]

Arguments to be added to the command line

=item commandline

A full commandline to run via C<system()>.
During execution, the environment variable PERL is set
to $^X (but with an absolute path). If C<commandline> is specified,
C<args> is not used.

=item eexpect [hash]

Extended C<expect>. This is a hash reference with four allowed keys,
C<mode>, C<timeout>, C<reuse>, and C<talk>.

C<mode> may have the values C<deterministic> for the case where all
questions come in the order written down and C<anyorder> for the case
where the questions may come in any order. The default mode is
C<deterministic>.

C<timeout> denotes a timeout in seconds. Floating-point timeouts are
OK. With C<mode=deterministic>, the timeout denotes the
timeout per question; with C<mode=anyorder> it denotes the
timeout per byte received from the stream or questions.

C<talk> is a reference to an array that contains alternating questions
and answers. Questions are regular expressions and answers are literal
strings. The Expect module watches the stream from the
execution of the external program (C<perl Makefile.PL>, C<perl
Build.PL>, C<make>, etc.).

For C<mode=deterministic>, the CPAN.pm injects the
corresponding answer as soon as the stream matches the regular expression.

For C<mode=anyorder> CPAN.pm answers a question as soon
as the timeout is reached for the next byte in the input stream. In
this mode you can use the C<reuse> parameter to decide what will
happen with a question-answer pair after it has been used. In the
default case (reuse=0) it is removed from the array, avoiding being
used again accidentally. If you want to answer the
question C<Do you really want to do that> several times, then it must
be included in the array at least as often as you want this answer to
be given. Setting the parameter C<reuse> to 1 makes this repetition
unnecessary.

=item env [hash]

Environment variables to be set during the command

=item expect [array]

C<< expect: <array> >> is a short notation for

eexpect:
    mode: deterministic
    timeout: 15
    talk: <array>

=back

=head2 Schema verification with C<Kwalify>

If you have the C<Kwalify> module installed (which is part of the
Bundle::CPANxxl), then all your distroprefs files are checked for
syntactic correctness.

=head2 Example Distroprefs Files

C<CPAN.pm> comes with a collection of example YAML files. Note that these
are really just examples and should not be used without care because
they cannot fit everybody's purpose. After all, the authors of the
packages that ask questions had a need to ask, so you should watch
their questions and adjust the examples to your environment and your
needs. You have been warned:-)

=head1 PROGRAMMER'S INTERFACE

If you do not enter the shell, shell commands are 
available both as methods (C<CPAN::Shell-E<gt>install(...)>) and as
functions in the calling package (C<install(...)>).  Before calling low-level
commands, it makes sense to initialize components of CPAN you need, e.g.:

  CPAN::HandleConfig->load;
  CPAN::Shell::setup_output;
  CPAN::Index->reload;

High-level commands do such initializations automatically.

There's currently only one class that has a stable interface -
CPAN::Shell. All commands that are available in the CPAN shell are
methods of the class CPAN::Shell. Each of the commands that produce
listings of modules (C<r>, C<autobundle>, C<u>) also return a list of
the IDs of all modules within the list.

=over 2

=item expand($type,@things)

The IDs of all objects available within a program are strings that can
be expanded to the corresponding real objects with the
C<CPAN::Shell-E<gt>expand("Module",@things)> method. Expand returns a
list of CPAN::Module objects according to the C<@things> arguments
given. In scalar context, it returns only the first element of the
list.

=item expandany(@things)

Like expand, but returns objects of the appropriate type, i.e.
CPAN::Bundle objects for bundles, CPAN::Module objects for modules, and
CPAN::Distribution objects for distributions. Note: it does not expand
to CPAN::Author objects.

=item Programming Examples

This enables the programmer to do operations that combine
functionalities that are available in the shell.

    # install everything that is outdated on my disk:
    perl -MCPAN -e 'CPAN::Shell->install(CPAN::Shell->r)'

    # install my favorite programs if necessary:
    for $mod (qw(Net::FTP Digest::SHA Data::Dumper)) {
        CPAN::Shell->install($mod);
    }

    # list all modules on my disk that have no VERSION number
    for $mod (CPAN::Shell->expand("Module","/./")) {
        next unless $mod->inst_file;
        # MakeMaker convention for undefined $VERSION:
        next unless $mod->inst_version eq "undef";
        print "No VERSION in ", $mod->id, "\n";
    }

    # find out which distribution on CPAN contains a module:
    print CPAN::Shell->expand("Module","Apache::Constants")->cpan_file

Or if you want to schedule a I<cron> job to watch CPAN, you could list
all modules that need updating. First a quick and dirty way:

    perl -e 'use CPAN; CPAN::Shell->r;'

If you don't want any output should all modules be
up to date, parse the output of above command for the regular
expression C</modules are up to date/> and decide to mail the output
only if it doesn't match. 

If you prefer to do it more in a programmerish style in one single
process, something like this may better suit you:

  # list all modules on my disk that have newer versions on CPAN
  for $mod (CPAN::Shell->expand("Module","/./")) {
    next unless $mod->inst_file;
    next if $mod->uptodate;
    printf "Module %s is installed as %s, could be updated to %s from CPAN\n",
        $mod->id, $mod->inst_version, $mod->cpan_version;
  }

If that gives too much output every day, you may want to
watch only for three modules. You can write

  for $mod (CPAN::Shell->expand("Module","/Apache|LWP|CGI/")) {

as the first line instead. Or you can combine some of the above
tricks:

  # watch only for a new mod_perl module
  $mod = CPAN::Shell->expand("Module","mod_perl");
  exit if $mod->uptodate;
  # new mod_perl arrived, let me know all update recommendations
  CPAN::Shell->r;

=back

=head2 Methods in the other Classes

=over 4

=item CPAN::Author::as_glimpse()

Returns a one-line description of the author

=item CPAN::Author::as_string()

Returns a multi-line description of the author

=item CPAN::Author::email()

Returns the author's email address

=item CPAN::Author::fullname()

Returns the author's name

=item CPAN::Author::name()

An alias for fullname

=item CPAN::Bundle::as_glimpse()

Returns a one-line description of the bundle

=item CPAN::Bundle::as_string()

Returns a multi-line description of the bundle

=item CPAN::Bundle::clean()

Recursively runs the C<clean> method on all items contained in the bundle.

=item CPAN::Bundle::contains()

Returns a list of objects' IDs contained in a bundle. The associated
objects may be bundles, modules or distributions.

=item CPAN::Bundle::force($method,@args)

Forces CPAN to perform a task that it normally would have refused to
do. Force takes as arguments a method name to be called and any number
of additional arguments that should be passed to the called method.
The internals of the object get the needed changes so that CPAN.pm
does not refuse to take the action. The C<force> is passed recursively
to all contained objects. See also the section above on the C<force>
and the C<fforce> pragma.

=item CPAN::Bundle::get()

Recursively runs the C<get> method on all items contained in the bundle

=item CPAN::Bundle::inst_file()

Returns the highest installed version of the bundle in either @INC or
C<$CPAN::Config->{cpan_home}>. Note that this is different from
CPAN::Module::inst_file.

=item CPAN::Bundle::inst_version()

Like CPAN::Bundle::inst_file, but returns the $VERSION

=item CPAN::Bundle::uptodate()

Returns 1 if the bundle itself and all its members are uptodate.

=item CPAN::Bundle::install()

Recursively runs the C<install> method on all items contained in the bundle

=item CPAN::Bundle::make()

Recursively runs the C<make> method on all items contained in the bundle

=item CPAN::Bundle::readme()

Recursively runs the C<readme> method on all items contained in the bundle

=item CPAN::Bundle::test()

Recursively runs the C<test> method on all items contained in the bundle

=item CPAN::Distribution::as_glimpse()

Returns a one-line description of the distribution

=item CPAN::Distribution::as_string()

Returns a multi-line description of the distribution

=item CPAN::Distribution::author

Returns the CPAN::Author object of the maintainer who uploaded this
distribution

=item CPAN::Distribution::pretty_id()

Returns a string of the form "AUTHORID/TARBALL", where AUTHORID is the
author's PAUSE ID and TARBALL is the distribution filename.

=item CPAN::Distribution::base_id()

Returns the distribution filename without any archive suffix.  E.g
"Foo-Bar-0.01"

=item CPAN::Distribution::clean()

Changes to the directory where the distribution has been unpacked and
runs C<make clean> there.

=item CPAN::Distribution::containsmods()

Returns a list of IDs of modules contained in a distribution file.
Works only for distributions listed in the 02packages.details.txt.gz
file. This typically means that just most recent version of a
distribution is covered.

=item CPAN::Distribution::cvs_import()

Changes to the directory where the distribution has been unpacked and
runs something like

    cvs -d $cvs_root import -m $cvs_log $cvs_dir $userid v$version

there.

=item CPAN::Distribution::dir()

Returns the directory into which this distribution has been unpacked.

=item CPAN::Distribution::force($method,@args)

Forces CPAN to perform a task that it normally would have refused to
do. Force takes as arguments a method name to be called and any number
of additional arguments that should be passed to the called method.
The internals of the object get the needed changes so that CPAN.pm
does not refuse to take the action. See also the section above on the
C<force> and the C<fforce> pragma.

=item CPAN::Distribution::get()

Downloads the distribution from CPAN and unpacks it. Does nothing if
the distribution has already been downloaded and unpacked within the
current session.

=item CPAN::Distribution::install()

Changes to the directory where the distribution has been unpacked and
runs the external command C<make install> there. If C<make> has not
yet been run, it will be run first. A C<make test> is issued in
any case and if this fails, the install is cancelled. The
cancellation can be avoided by letting C<force> run the C<install> for
you.

This install method only has the power to install the distribution if
there are no dependencies in the way. To install an object along with all 
its dependencies, use CPAN::Shell->install.

Note that install() gives no meaningful return value. See uptodate().

=item CPAN::Distribution::install_tested()

Install all distributions that have tested sucessfully but
not yet installed. See also C<is_tested>.

=item CPAN::Distribution::isa_perl()

Returns 1 if this distribution file seems to be a perl distribution.
Normally this is derived from the file name only, but the index from
CPAN can contain a hint to achieve a return value of true for other
filenames too.

=item CPAN::Distribution::look()

Changes to the directory where the distribution has been unpacked and
opens a subshell there. Exiting the subshell returns.

=item CPAN::Distribution::make()

First runs the C<get> method to make sure the distribution is
downloaded and unpacked. Changes to the directory where the
distribution has been unpacked and runs the external commands C<perl
Makefile.PL> or C<perl Build.PL> and C<make> there.

=item CPAN::Distribution::perldoc()

Downloads the pod documentation of the file associated with a
distribution (in HTML format) and runs it through the external
command I<lynx> specified in C<$CPAN::Config->{lynx}>. If I<lynx>
isn't available, it converts it to plain text with the external
command I<html2text> and runs it through the pager specified
in C<$CPAN::Config->{pager}>

=item CPAN::Distribution::prefs()

Returns the hash reference from the first matching YAML file that the
user has deposited in the C<prefs_dir/> directory. The first
succeeding match wins. The files in the C<prefs_dir/> are processed
alphabetically, and the canonical distroname (e.g.
AUTHOR/Foo-Bar-3.14.tar.gz) is matched against the regular expressions
stored in the $root->{match}{distribution} attribute value.
Additionally all module names contained in a distribution are matched
against the regular expressions in the $root->{match}{module} attribute
value. The two match values are ANDed together. Each of the two
attributes are optional.

=item CPAN::Distribution::prereq_pm()

Returns the hash reference that has been announced by a distribution
as the C<requires> and C<build_requires> elements. These can be
declared either by the C<META.yml> (if authoritative) or can be
deposited after the run of C<Build.PL> in the file C<./_build/prereqs>
or after the run of C<Makfile.PL> written as the C<PREREQ_PM> hash in
a comment in the produced C<Makefile>. I<Note>: this method only works
after an attempt has been made to C<make> the distribution. Returns
undef otherwise.

=item CPAN::Distribution::readme()

Downloads the README file associated with a distribution and runs it
through the pager specified in C<$CPAN::Config->{pager}>.

=item CPAN::Distribution::reports()

Downloads report data for this distribution from cpantesters.perl.org
and displays a subset of them.

=item CPAN::Distribution::read_yaml()

Returns the content of the META.yml of this distro as a hashref. Note:
works only after an attempt has been made to C<make> the distribution.
Returns undef otherwise. Also returns undef if the content of META.yml
is not authoritative. (The rules about what exactly makes the content
authoritative are still in flux.)

=item CPAN::Distribution::test()

Changes to the directory where the distribution has been unpacked and
runs C<make test> there.

=item CPAN::Distribution::uptodate()

Returns 1 if all the modules contained in the distribution are
uptodate. Relies on containsmods.

=item CPAN::Index::force_reload()

Forces a reload of all indices.

=item CPAN::Index::reload()

Reloads all indices if they have not been read for more than
C<$CPAN::Config->{index_expire}> days.

=item CPAN::InfoObj::dump()

CPAN::Author, CPAN::Bundle, CPAN::Module, and CPAN::Distribution
inherit this method. It prints the data structure associated with an
object. Useful for debugging. Note: the data structure is considered
internal and thus subject to change without notice.

=item CPAN::Module::as_glimpse()

Returns a one-line description of the module in four columns: The
first column contains the word C<Module>, the second column consists
of one character: an equals sign if this module is already installed
and uptodate, a less-than sign if this module is installed but can be
upgraded, and a space if the module is not installed. The third column
is the name of the module and the fourth column gives maintainer or
distribution information.

=item CPAN::Module::as_string()

Returns a multi-line description of the module

=item CPAN::Module::clean()

Runs a clean on the distribution associated with this module.

=item CPAN::Module::cpan_file()

Returns the filename on CPAN that is associated with the module.

=item CPAN::Module::cpan_version()

Returns the latest version of this module available on CPAN.

=item CPAN::Module::cvs_import()

Runs a cvs_import on the distribution associated with this module.

=item CPAN::Module::description()

Returns a 44 character description of this module. Only available for
modules listed in The Module List (CPAN/modules/00modlist.long.html
or 00modlist.long.txt.gz)

=item CPAN::Module::distribution()

Returns the CPAN::Distribution object that contains the current
version of this module.

=item CPAN::Module::dslip_status()

Returns a hash reference. The keys of the hash are the letters C<D>,
C<S>, C<L>, C<I>, and <P>, for development status, support level,
language, interface and public licence respectively. The data for the
DSLIP status are collected by pause.perl.org when authors register
their namespaces. The values of the 5 hash elements are one-character
words whose meaning is described in the table below. There are also 5
hash elements C<DV>, C<SV>, C<LV>, C<IV>, and <PV> that carry a more
verbose value of the 5 status variables.

Where the 'DSLIP' characters have the following meanings:

  D - Development Stage  (Note: *NO IMPLIED TIMESCALES*):
    i   - Idea, listed to gain consensus or as a placeholder
    c   - under construction but pre-alpha (not yet released)
    a/b - Alpha/Beta testing
    R   - Released
    M   - Mature (no rigorous definition)
    S   - Standard, supplied with Perl 5

  S - Support Level:
    m   - Mailing-list
    d   - Developer
    u   - Usenet newsgroup comp.lang.perl.modules
    n   - None known, try comp.lang.perl.modules
    a   - abandoned; volunteers welcome to take over maintainance

  L - Language Used:
    p   - Perl-only, no compiler needed, should be platform independent
    c   - C and perl, a C compiler will be needed
    h   - Hybrid, written in perl with optional C code, no compiler needed
    +   - C++ and perl, a C++ compiler will be needed
    o   - perl and another language other than C or C++

  I - Interface Style
    f   - plain Functions, no references used
    h   - hybrid, object and function interfaces available
    n   - no interface at all (huh?)
    r   - some use of unblessed References or ties
    O   - Object oriented using blessed references and/or inheritance

  P - Public License
    p   - Standard-Perl: user may choose between GPL and Artistic
    g   - GPL: GNU General Public License
    l   - LGPL: "GNU Lesser General Public License" (previously known as
          "GNU Library General Public License")
    b   - BSD: The BSD License
    a   - Artistic license alone
    2   - Artistic license 2.0 or later
    o   - open source: appoved by www.opensource.org
    d   - allows distribution without restrictions
    r   - restricted distribtion
    n   - no license at all

=item CPAN::Module::force($method,@args)

Forces CPAN to perform a task it would normally refuse to
do. Force takes as arguments a method name to be invoked and any number
of additional arguments to pass that method.
The internals of the object get the needed changes so that CPAN.pm
does not refuse to take the action. See also the section above on the
C<force> and the C<fforce> pragma.

=item CPAN::Module::get()

Runs a get on the distribution associated with this module.

=item CPAN::Module::inst_file()

Returns the filename of the module found in @INC. The first file found
is reported, just as perl itself stops searching @INC once it finds a
module.

=item CPAN::Module::available_file()

Returns the filename of the module found in PERL5LIB or @INC. The
first file found is reported. The advantage of this method over
C<inst_file> is that modules that have been tested but not yet
installed are included because PERL5LIB keeps track of tested modules.

=item CPAN::Module::inst_version()

Returns the version number of the installed module in readable format.

=item CPAN::Module::available_version()

Returns the version number of the available module in readable format.

=item CPAN::Module::install()

Runs an C<install> on the distribution associated with this module.

=item CPAN::Module::look()

Changes to the directory where the distribution associated with this
module has been unpacked and opens a subshell there. Exiting the
subshell returns.

=item CPAN::Module::make()

Runs a C<make> on the distribution associated with this module.

=item CPAN::Module::manpage_headline()

If module is installed, peeks into the module's manpage, reads the
headline, and returns it. Moreover, if the module has been downloaded
within this session, does the equivalent on the downloaded module even
if it hasn't been installed yet.

=item CPAN::Module::perldoc()

Runs a C<perldoc> on this module.

=item CPAN::Module::readme()

Runs a C<readme> on the distribution associated with this module.

=item CPAN::Module::reports()

Calls the reports() method on the associated distribution object.

=item CPAN::Module::test()

Runs a C<test> on the distribution associated with this module.

=item CPAN::Module::uptodate()

Returns 1 if the module is installed and up-to-date.

=item CPAN::Module::userid()

Returns the author's ID of the module.

=back

=head2 Cache Manager

Currently the cache manager only keeps track of the build directory
($CPAN::Config->{build_dir}). It is a simple FIFO mechanism that
deletes complete directories below C<build_dir> as soon as the size of
all directories there gets bigger than $CPAN::Config->{build_cache}
(in MB). The contents of this cache may be used for later
re-installations that you intend to do manually, but will never be
trusted by CPAN itself. This is due to the fact that the user might
use these directories for building modules on different architectures.

There is another directory ($CPAN::Config->{keep_source_where}) where
the original distribution files are kept. This directory is not
covered by the cache manager and must be controlled by the user. If
you choose to have the same directory as build_dir and as
keep_source_where directory, then your sources will be deleted with
the same fifo mechanism.

=head2 Bundles

A bundle is just a perl module in the namespace Bundle:: that does not
define any functions or methods. It usually only contains documentation.

It starts like a perl module with a package declaration and a $VERSION
variable. After that the pod section looks like any other pod with the
only difference being that I<one special pod section> exists starting with
(verbatim):

    =head1 CONTENTS

In this pod section each line obeys the format

        Module_Name [Version_String] [- optional text]

The only required part is the first field, the name of a module
(e.g. Foo::Bar, ie. I<not> the name of the distribution file). The rest
of the line is optional. The comment part is delimited by a dash just
as in the man page header.

The distribution of a bundle should follow the same convention as
other distributions.

Bundles are treated specially in the CPAN package. If you say 'install
Bundle::Tkkit' (assuming such a bundle exists), CPAN will install all
the modules in the CONTENTS section of the pod. You can install your
own Bundles locally by placing a conformant Bundle file somewhere into
your @INC path. The autobundle() command which is available in the
shell interface does that for you by including all currently installed
modules in a snapshot bundle file.

=head1 PREREQUISITES

If you have a local mirror of CPAN and can access all files with
"file:" URLs, then you only need a perl later than perl5.003 to run
this module. Otherwise Net::FTP is strongly recommended. LWP may be
required for non-UNIX systems, or if your nearest CPAN site is
associated with a URL that is not C<ftp:>.

If you have neither Net::FTP nor LWP, there is a fallback mechanism
implemented for an external ftp command or for an external lynx
command.

=head1 UTILITIES

=head2 Finding packages and VERSION

This module presumes that all packages on CPAN

=over 2

=item *

declare their $VERSION variable in an easy to parse manner. This
prerequisite can hardly be relaxed because it consumes far too much
memory to load all packages into the running program just to determine
the $VERSION variable. Currently all programs that are dealing with
version use something like this

    perl -MExtUtils::MakeMaker -le \
        'print MM->parse_version(shift)' filename

If you are author of a package and wonder if your $VERSION can be
parsed, please try the above method.

=item *

come as compressed or gzipped tarfiles or as zip files and contain a
C<Makefile.PL> or C<Build.PL> (well, we try to handle a bit more, but
with little enthusiasm).

=back

=head2 Debugging

Debugging this module is more than a bit complex due to interference from
the software producing the indices on CPAN, the mirroring process on CPAN,
packaging, configuration, synchronicity, and even (gasp!) due to bugs
within the CPAN.pm module itself.

For debugging the code of CPAN.pm itself in interactive mode, some 
debugging aid can be turned on for most packages within
CPAN.pm with one of

=over 2

=item o debug package...

sets debug mode for packages.

=item o debug -package...

unsets debug mode for packages.

=item o debug all

turns debugging on for all packages.

=item o debug number

=back

which sets the debugging packages directly. Note that C<o debug 0>
turns debugging off.

What seems a successful strategy is the combination of C<reload
cpan> and the debugging switches. Add a new debug statement while
running in the shell and then issue a C<reload cpan> and see the new
debugging messages immediately without losing the current context.

C<o debug> without an argument lists the valid package names and the
current set of packages in debugging mode. C<o debug> has built-in
completion support.

For debugging of CPAN data there is the C<dump> command which takes
the same arguments as make/test/install and outputs each object's
Data::Dumper dump. If an argument looks like a perl variable and
contains one of C<$>, C<@> or C<%>, it is eval()ed and fed to
Data::Dumper directly.

=head2 Floppy, Zip, Offline Mode

CPAN.pm works nicely without network access, too. If you maintain machines
that are not networked at all, you should consider working with C<file:>
URLs. You'll have to collect your modules somewhere first. So
you might use CPAN.pm to put together all you need on a networked
machine. Then copy the $CPAN::Config->{keep_source_where} (but not
$CPAN::Config->{build_dir}) directory on a floppy. This floppy is kind
of a personal CPAN. CPAN.pm on the non-networked machines works nicely
with this floppy. See also below the paragraph about CD-ROM support.

=head2 Basic Utilities for Programmers

=over 2

=item has_inst($module)

Returns true if the module is installed. Used to load all modules into
the running CPAN.pm that are considered optional. The config variable
C<dontload_list> intercepts the C<has_inst()> call such
that an optional module is not loaded despite being available. For
example, the following command will prevent C<YAML.pm> from being
loaded:

    cpan> o conf dontload_list push YAML

See the source for details.

=item has_usable($module)

Returns true if the module is installed and in a usable state. Only
useful for a handful of modules that are used internally. See the
source for details.

=item instance($module)

The constructor for all the singletons used to represent modules,
distributions, authors, and bundles. If the object already exists, this
method returns the object; otherwise, it calls the constructor.

=back

=head1 SECURITY

There's no strong security layer in CPAN.pm. CPAN.pm helps you to
install foreign, unmasked, unsigned code on your machine. We compare
to a checksum that comes from the net just as the distribution file
itself. But we try to make it easy to add security on demand:

=head2 Cryptographically signed modules

Since release 1.77, CPAN.pm has been able to verify cryptographically
signed module distributions using Module::Signature.  The CPAN modules
can be signed by their authors, thus giving more security.  The simple
unsigned MD5 checksums that were used before by CPAN protect mainly
against accidental file corruption.

You will need to have Module::Signature installed, which in turn
requires that you have at least one of Crypt::OpenPGP module or the
command-line F<gpg> tool installed.

You will also need to be able to connect over the Internet to the public
keyservers, like pgp.mit.edu, and their port 11731 (the HKP protocol).

The configuration parameter check_sigs is there to turn signature
checking on or off.

=head1 EXPORT

Most functions in package CPAN are exported by default. The reason
for this is that the primary use is intended for the cpan shell or for
one-liners.

=head1 ENVIRONMENT

When the CPAN shell enters a subshell via the look command, it sets
the environment CPAN_SHELL_LEVEL to 1, or increments that variable if it is
already set.

When CPAN runs, it sets the environment variable PERL5_CPAN_IS_RUNNING
to the ID of the running process. It also sets
PERL5_CPANPLUS_IS_RUNNING to prevent runaway processes which could
happen with older versions of Module::Install.

When running C<perl Makefile.PL>, the environment variable
C<PERL5_CPAN_IS_EXECUTING> is set to the full path of the
C<Makefile.PL> that is being executed. This prevents runaway processes
with newer versions of Module::Install.

When the config variable ftp_passive is set, all downloads will be run
with the environment variable FTP_PASSIVE set to this value. This is
in general a good idea as it influences both Net::FTP and LWP based
connections. The same effect can be achieved by starting the cpan
shell with this environment variable set. For Net::FTP alone, one can
also always set passive mode by running libnetcfg.

=head1 POPULATE AN INSTALLATION WITH LOTS OF MODULES

Populating a freshly installed perl with one's favorite modules is pretty
easy if you maintain a private bundle definition file. To get a useful
blueprint of a bundle definition file, the command autobundle can be used
on the CPAN shell command line. This command writes a bundle definition
file for all modules installed for the current perl
interpreter. It's recommended to run this command once only, and from then
on maintain the file manually under a private name, say
Bundle/my_bundle.pm. With a clever bundle file you can then simply say

    cpan> install Bundle::my_bundle

then answer a few questions and go out for coffee (possibly
even in a different city).

Maintaining a bundle definition file means keeping track of two
things: dependencies and interactivity. CPAN.pm sometimes fails on
calculating dependencies because not all modules define all MakeMaker
attributes correctly, so a bundle definition file should specify
prerequisites as early as possible. On the other hand, it's 
annoying that so many distributions need some interactive configuring. So
what you can try to accomplish in your private bundle file is to have the
packages that need to be configured early in the file and the gentle
ones later, so you can go out for cofeee after a few minutes and leave CPAN.pm
to churn away untended.

=head1 WORKING WITH CPAN.pm BEHIND FIREWALLS

Thanks to Graham Barr for contributing the following paragraphs about
the interaction between perl, and various firewall configurations. For
further information on firewalls, it is recommended to consult the
documentation that comes with the I<ncftp> program. If you are unable to
go through the firewall with a simple Perl setup, it is likely
that you can configure I<ncftp> so that it works through your firewall.

=head2 Three basic types of firewalls

Firewalls can be categorized into three basic types.

=over 4

=item http firewall

This is when the firewall machine runs a web server, and to access the
outside world, you must do so via that web server. If you set environment
variables like http_proxy or ftp_proxy to values beginning with http://,
or in your web browser you've proxy information set, then you know
you are running behind an http firewall.

To access servers outside these types of firewalls with perl (even for
ftp), you need LWP.

=item ftp firewall

This where the firewall machine runs an ftp server. This kind of
firewall will only let you access ftp servers outside the firewall.
This is usually done by connecting to the firewall with ftp, then
entering a username like "user@outside.host.com".

To access servers outside these type of firewalls with perl, you
need Net::FTP.

=item One-way visibility

One-way visibility means these firewalls try to make themselves 
invisible to users inside the firewall. An FTP data connection is
normally created by sending your IP address to the remote server and then
listening for the return connection. But the remote server will not be able to
connect to you because of the firewall. For these types of firewall,
FTP connections need to be done in a passive mode.

There are two that I can think off.

=over 4

=item SOCKS

If you are using a SOCKS firewall, you will need to compile perl and link
it with the SOCKS library.  This is what is normally called a 'socksified'
perl. With this executable you will be able to connect to servers outside
the firewall as if it were not there.

=item IP Masquerade

This is when the firewall implemented in the kernel (via NAT, or networking
address translation), it allows you to hide a complete network behind one
IP address. With this firewall no special compiling is needed as you can
access hosts directly.

For accessing ftp servers behind such firewalls you usually need to
set the environment variable C<FTP_PASSIVE> or the config variable
ftp_passive to a true value.

=back

=back

=head2 Configuring lynx or ncftp for going through a firewall

If you can go through your firewall with e.g. lynx, presumably with a
command such as

    /usr/local/bin/lynx -pscott:tiger

then you would configure CPAN.pm with the command

    o conf lynx "/usr/local/bin/lynx -pscott:tiger"

That's all. Similarly for ncftp or ftp, you would configure something
like

    o conf ncftp "/usr/bin/ncftp -f /home/scott/ncftplogin.cfg"

Your mileage may vary...

=head1 FAQ

=over 4

=item 1)

I installed a new version of module X but CPAN keeps saying,
I have the old version installed

Probably you B<do> have the old version installed. This can
happen if a module installs itself into a different directory in the
@INC path than it was previously installed. This is not really a
CPAN.pm problem, you would have the same problem when installing the
module manually. The easiest way to prevent this behaviour is to add
the argument C<UNINST=1> to the C<make install> call, and that is why
many people add this argument permanently by configuring

  o conf make_install_arg UNINST=1

=item 2)

So why is UNINST=1 not the default?

Because there are people who have their precise expectations about who
may install where in the @INC path and who uses which @INC array. In
fine tuned environments C<UNINST=1> can cause damage.

=item 3)

I want to clean up my mess, and install a new perl along with
all modules I have. How do I go about it?

Run the autobundle command for your old perl and optionally rename the
resulting bundle file (e.g. Bundle/mybundle.pm), install the new perl
with the Configure option prefix, e.g.

    ./Configure -Dprefix=/usr/local/perl-5.6.78.9

Install the bundle file you produced in the first step with something like

    cpan> install Bundle::mybundle

and you're done.

=item 4)

When I install bundles or multiple modules with one command
there is too much output to keep track of.

You may want to configure something like

  o conf make_arg "| tee -ai /root/.cpan/logs/make.out"
  o conf make_install_arg "| tee -ai /root/.cpan/logs/make_install.out"

so that STDOUT is captured in a file for later inspection.


=item 5)

I am not root, how can I install a module in a personal directory?

First of all, you will want to use your own configuration, not the one
that your root user installed. If you do not have permission to write
in the cpan directory that root has configured, you will be asked if
you want to create your own config. Answering "yes" will bring you into
CPAN's configuration stage, using the system config for all defaults except
things that have to do with CPAN's work directory, saving your choices to
your MyConfig.pm file.

You can also manually initiate this process with the following command:

    % perl -MCPAN -e 'mkmyconfig'

or by running

    mkmyconfig

from the CPAN shell.

You will most probably also want to configure something like this:

  o conf makepl_arg "LIB=~/myperl/lib \
                    INSTALLMAN1DIR=~/myperl/man/man1 \
                    INSTALLMAN3DIR=~/myperl/man/man3 \
                    INSTALLSCRIPT=~/myperl/bin \
                    INSTALLBIN=~/myperl/bin"

and then (oh joy) the equivalent command for Module::Build. That would
be

  o conf mbuildpl_arg "--lib=~/myperl/lib \
                    --installman1dir=~/myperl/man/man1 \
                    --installman3dir=~/myperl/man/man3 \
                    --installscript=~/myperl/bin \
                    --installbin=~/myperl/bin"

You can make this setting permanent like all C<o conf> settings with
C<o conf commit> or by setting C<auto_commit> beforehand.

You will have to add ~/myperl/man to the MANPATH environment variable
and also tell your perl programs to look into ~/myperl/lib, e.g. by
including

  use lib "$ENV{HOME}/myperl/lib";

or setting the PERL5LIB environment variable.

While we're speaking about $ENV{HOME}, it might be worth mentioning,
that for Windows we use the File::HomeDir module that provides an
equivalent to the concept of the home directory on Unix.

Another thing you should bear in mind is that the UNINST parameter can
be dangerous when you are installing into a private area because you
might accidentally remove modules that other people depend on that are
not using the private area.

=item 6)

How to get a package, unwrap it, and make a change before building it?

Have a look at the C<look> (!) command.

=item 7)

I installed a Bundle and had a couple of fails. When I
retried, everything resolved nicely. Can this be fixed to work
on first try?

The reason for this is that CPAN does not know the dependencies of all
modules when it starts out. To decide about the additional items to
install, it just uses data found in the META.yml file or the generated
Makefile. An undetected missing piece breaks the process. But it may
well be that your Bundle installs some prerequisite later than some
depending item and thus your second try is able to resolve everything.
Please note, CPAN.pm does not know the dependency tree in advance and
cannot sort the queue of things to install in a topologically correct
order. It resolves perfectly well B<if> all modules declare the
prerequisites correctly with the PREREQ_PM attribute to MakeMaker or
the C<requires> stanza of Module::Build. For bundles which fail and
you need to install often, it is recommended to sort the Bundle
definition file manually.

=item 8)

In our intranet, we have many modules for internal use. How
can I integrate these modules with CPAN.pm but without uploading
the modules to CPAN?

Have a look at the CPAN::Site module.

=item 9)

When I run CPAN's shell, I get an error message about things in my
C</etc/inputrc> (or C<~/.inputrc>) file.

These are readline issues and can only be fixed by studying readline
configuration on your architecture and adjusting the referenced file
accordingly. Please make a backup of the C</etc/inputrc> or C<~/.inputrc>
and edit them. Quite often harmless changes like uppercasing or
lowercasing some arguments solves the problem.

=item 10)

Some authors have strange characters in their names.

Internally CPAN.pm uses the UTF-8 charset. If your terminal is
expecting ISO-8859-1 charset, a converter can be activated by setting
term_is_latin to a true value in your config file. One way of doing so
would be

    cpan> o conf term_is_latin 1

If other charset support is needed, please file a bugreport against
CPAN.pm at rt.cpan.org and describe your needs. Maybe we can extend
the support or maybe UTF-8 terminals become widely available.

Note: this config variable is deprecated and will be removed in a
future version of CPAN.pm. It will be replaced with the conventions
around the family of $LANG and $LC_* environment variables.

=item 11)

When an install fails for some reason and then I correct the error
condition and retry, CPAN.pm refuses to install the module, saying
C<Already tried without success>.

Use the force pragma like so

  force install Foo::Bar

Or you can use

  look Foo::Bar

and then C<make install> directly in the subshell.

=item 12)

How do I install a "DEVELOPER RELEASE" of a module?

By default, CPAN will install the latest non-developer release of a
module. If you want to install a dev release, you have to specify the
partial path starting with the author id to the tarball you wish to
install, like so:

    cpan> install KWILLIAMS/Module-Build-0.27_07.tar.gz

Note that you can use the C<ls> command to get this path listed.

=item 13)

How do I install a module and all its dependencies from the commandline,
without being prompted for anything, despite my CPAN configuration
(or lack thereof)?

CPAN uses ExtUtils::MakeMaker's prompt() function to ask its questions, so
if you set the PERL_MM_USE_DEFAULT environment variable, you shouldn't be
asked any questions at all (assuming the modules you are installing are
nice about obeying that variable as well):

    % PERL_MM_USE_DEFAULT=1 perl -MCPAN -e 'install My::Module'

=item 14)

How do I create a Module::Build based Build.PL derived from an
ExtUtils::MakeMaker focused Makefile.PL?

http://search.cpan.org/search?query=Module::Build::Convert

http://www.refcnt.org/papers/module-build-convert

=item 15)

I'm frequently irritated with the CPAN shell's inability to help me
select a good mirror.

The urllist config parameter is yours. You can add and remove sites at
will. You should find out which sites have the best uptodateness,
bandwidth, reliability, etc. and are topologically close to you. Some
people prefer fast downloads, others uptodateness, others reliability.
You decide which to try in which order.

Henk P. Penning maintains a site that collects data about CPAN sites:

  http://www.cs.uu.nl/people/henkp/mirmon/cpan.html

Also, feel free to play with experimental features. Run

  o conf init randomize_urllist ftpstats_period ftpstats_size

and choose your favorite parameters. After a few downloads running the
C<hosts> command will probably assist you in choosing the best mirror
sites.

=item 16)

Why do I get asked the same questions every time I start the shell?

You can make your configuration changes permanent by calling the
command C<o conf commit>. Alternatively set the C<auto_commit>
variable to true by running C<o conf init auto_commit> and answering
the following question with yes.

=item 17)

Older versions of CPAN.pm had the original root directory of all
tarballs in the build directory. Now there are always random
characters appended to these directory names. Why was this done?

The random characters are provided by File::Temp and ensure that each
module's individual build directory is unique. This makes running
CPAN.pm in concurrent processes simultaneously safe.

=item 18)

Speaking of the build directory. Do I have to clean it up myself?

You have the choice to set the config variable C<scan_cache> to
C<never>. Then you must clean it up yourself. The other possible
value, C<atstart> only cleans up the build directory when you start
the CPAN shell. If you never start up the CPAN shell, you probably
also have to clean up the build directory yourself.

=back

=head1 COMPATIBILITY

=head2 OLD PERL VERSIONS

CPAN.pm is regularly tested to run under 5.004, 5.005, and assorted
newer versions. It is getting more and more difficult to get the
minimal prerequisites working on older perls. It is close to
impossible to get the whole Bundle::CPAN working there. If you're in
the position to have only these old versions, be advised that CPAN is
designed to work fine without the Bundle::CPAN installed.

To get things going, note that GBARR/Scalar-List-Utils-1.18.tar.gz is
compatible with ancient perls and that File::Temp is listed as a
prerequisite but CPAN has reasonable workarounds if it is missing.

=head2 CPANPLUS

This module and its competitor, the CPANPLUS module, are both much
cooler than the other. CPAN.pm is older. CPANPLUS was designed to be
more modular, but it was never intended to be compatible with CPAN.pm.

=head1 SECURITY ADVICE

This software enables you to upgrade software on your computer and so
is inherently dangerous because the newly installed software may
contain bugs and may alter the way your computer works or even make it
unusable. Please consider backing up your data before every upgrade.

=head1 BUGS

Please report bugs via L<http://rt.cpan.org/>

Before submitting a bug, please make sure that the traditional method
of building a Perl module package from a shell by following the
installation instructions of that package still works in your
environment.

=head1 AUTHOR

Andreas Koenig C<< <andk@cpan.org> >>

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=head1 TRANSLATIONS

Kawai,Takanori provides a Japanese translation of this manpage at
L<http://homepage3.nifty.com/hippo2000/perltips/CPAN.htm>

=head1 SEE ALSO

L<cpan>, L<CPAN::Nox>, L<CPAN::Version>

=cut
