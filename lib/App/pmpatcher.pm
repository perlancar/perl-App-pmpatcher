package App::pmpatcher;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use IPC::System::Options qw(system);
use String::ShellQuote;

our %SPEC;

$SPEC{pmpatcher} = {
    v => 1.1,
    summary => 'Apply a set of module patches on your Perl installation',
    description => <<'_',

You might have a set of patches that you want to apply on Perl modules on all
your Perl installation. For example, currently as of this writing I have this on
my `patches` directory:

    pm-OrePAN-Archive-0.08-support_no_index_file.patch
    pm-Pod-Elemental-PerlMunger-0.200002-DATA_encoding_fix.patch

These patches might be pending merge by the module maintainer, or are of private
nature so might never be merged, or of any other nature. Applying module patches
to an installation is a lightweight alternative to creating a fork for each of
these modules.

This utility helps you making the process of applying these patches more
convenient. Basically this utility just locates all the target modules and
feeds all of these patches to the `patch` program.

To use this utility, first of all you need to gather all your module patches in
a single directory (see `patches_dir` option). Also, you need to make sure that
all your `*.patch` files match this name pattern:

    pm-<MODULE-NAME-DASH-SEPARATED>-<VERSION>-<TOPIC>.patch

Then, to apply all the patches, you just call:

    % pmpatcher --patches-dir ~/patches

(Or, you might also want to put `patches_dir=/path/to/patches` into
`~/pmpatcher.conf` to save you from having to type the option repeatedly.)

Example result:

    % pmpatcher
    +--------------------------------------------------------------+--------+---------+
    | item_id                                                      | status | message |
    +--------------------------------------------------------------+--------+---------+
    | pm-OrePAN-Archive-0.08-support_no_index_file.patch           | 200    | Applied |
    | pm-Pod-Elemental-PerlMunger-0.200002-DATA_encoding_fix.patch | 200    | Applied |
    +--------------------------------------------------------------+--------+---------+

If you try to run it again, you might get:

    % pmpatcher
    +--------------------------------------------------------------+--------+-----------------+
    | item_id                                                      | status | message         |
    +--------------------------------------------------------------+--------+-----------------+
    | pm-OrePAN-Archive-0.08-support_no_index_file.patch           | 304    | Already applied |
    | pm-Pod-Elemental-PerlMunger-0.200002-DATA_encoding_fix.patch | 304    | Already applied |
    +--------------------------------------------------------------+--------+-----------------+

There's also a `--dry-run` and a `-R` (`--reverse`) option, just like `patch`.

_
    args => {
        patches_dir => {
            schema => 'str*',
            req => 1,
        },
        reverse => {
            schema => ['bool', is=>1],
            cmdline_aliases => {R=>{}},
        },
    },
    deps => {
        prog => 'patch',
    },
    features => {
        dry_run => 1,
    },
    links => [
        {url=>'prog:progpatcher'},
    ],
};
sub pmpatcher {
    require Module::Path::More;
    require Perinci::Object;

    my %args = @_;

    my $patches_dir = $args{patches_dir}
        or return [400, "Please specify patches_dir"];
    $patches_dir =~ s!/\z!!; # convenience

    log_trace("Opening patches_dir '%s' ...", $patches_dir);
    opendir my($dh), $patches_dir
        or return [500, "Can't open patches_dir '$patches_dir': $!"];

    my $envres = Perinci::Object::envresmulti();

  FILE:
    for my $fname (sort readdir $dh) {
        next if $fname eq '.' || $fname eq '..';
        log_trace("Considering file '%s' ...", $fname);
        unless ($fname =~ /\A
                           pm-
                           (\w+(?:-\w+)*)-
                           ([0-9][0-9._]*)-
                           ([^.]+)
                           \.patch\z/x) {
            log_trace("Skipped file '%s' (doesn't match pattern)", $fname);
            next FILE;
        }
        my ($mod0, $ver, $topic) = ($1, $2, $3);
        my $mod = $mod0; $mod =~ s!-!::!g;
        my $mod_pm = $mod0; $mod_pm =~ s!-!/!g; $mod_pm .= ".pm";

        my $mod_path = Module::Path::More::module_path(module=>$mod_pm);
        unless ($mod_path) {
            log_info("Skipping patch '%s' (module %s not installed)",
                        $fname, $mod);
            next FILE;
        }
        (my $mod_dir = $mod_path) =~ s!(.+)[/\\].+!$1!;

        open my($fh), "<", "$patches_dir/$fname" or do {
            log_error("Skipping patch '%s' (can't open file: %s)",
                         $fname, $!);
            $envres->add_result(500, "Can't open: $!", {item_id=>$fname});
            next FILE;
        };

        my $out;
        # first check if patch is already applied
        system(
            {shell=>1, log=>1, lang=>"C", capture_stdout=>\$out},
            join(" ",
                 "patch", "-d", shell_quote($mod_dir),
                 "-t", "--dry-run",
                 "<", shell_quote("$patches_dir/$fname"),
             ),
        );

        if ($?) {
            log_error("Skipping patch '%s' (can't patch(1) to detect applied: %s)",
                         $fname, $?);
            $envres->add_result(
                500, "Can't patch(1) to detect applied: $?", {item_id=>$fname});
            next FILE;
        }

        my $already_applied = 0;
        if ($out =~ /Reversed .*patch detected/) {
            $already_applied = 1;
        }

        if ($args{reverse}) {
            if (!$already_applied) {
                log_info("Skipping patch '%s' (already reversed)", $fname);
                $envres->add_result(
                    304, "Already reversed", {item_id=>$fname});
                next FILE;
            } else {
                if ($args{-dry_run}) {
                    $envres->add_result(
                        200, "Reverse-applying (dry-run)", {item_id=>$fname});
                    next FILE;
                }
                system(
                    {shell=>1, log=>1, lang=>"C", capture_stdout=>\$out},
                    join(" ",
                         "patch", "-d", shell_quote($mod_dir),
                         "--reverse",
                         "<", shell_quote("$patches_dir/$fname"),
                     ),
                );
                if ($?) {
                    log_error("Skipping patch '%s' (can't patch(2b) to reverse-apply: %s)",
                                 $fname, $?);
                    $envres->add_result(
                        500, "Can't patch(2b) to reverse-apply: $?", {item_id=>$fname});
                    next FILE;
                }
            }
        } else {
            if ($already_applied) {
                log_info("Skipping patch '%s' (already applied)", $fname);
                $envres->add_result(
                    304, "Already applied", {item_id=>$fname});
                next FILE;
            } else {
                if ($args{-dry_run}) {
                    $envres->add_result(
                        200, "Applying (dry-run)", {item_id=>$fname});
                    next FILE;
                }
                system(
                    {shell=>1, log=>1, lang=>"C", capture_stdout=>\$out},
                    join(" ",
                         "patch", "-d", shell_quote($mod_dir),
                         "--forward",
                         "<", shell_quote("$patches_dir/$fname"),
                     ),
                );
                if ($?) {
                    log_error("Skipping patch '%s' (can't patch(2) to apply: %s)",
                                 $fname, $?);
                    $envres->add_result(
                        500, "Can't patch(2) to apply: $?", {item_id=>$fname});
                    next FILE;
                }
            }
        }

        $envres->add_result(
            200, ($args{reverse} ? "Reverse-applied" : "Applied"),
            {item_id=>$fname});
    }

    my $res = $envres->as_struct;
    $res->[2] = $res->[3]{results};
    $res->[3]{'table.fields'} = [qw/item_id status message/];
    #$res->[3]{'table.hide_unknown_fields'} = 1;
    $res;
}

1;
#ABSTRACT:

=head1 SYNOPSIS

See L<pmpatcher> CLI.


=head1 DESCRIPTION
