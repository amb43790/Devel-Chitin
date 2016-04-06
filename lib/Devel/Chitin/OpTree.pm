package Devel::Chitin::OpTree;

use strict;
use warnings;

use Devel::Chitin::Version;

use Carp;
use Scalar::Util qw(blessed reftype weaken refaddr);
use B qw(ppname);

use Devel::Chitin::OpTree::UNOP;
use Devel::Chitin::OpTree::SVOP;
use Devel::Chitin::OpTree::PADOP;
use Devel::Chitin::OpTree::COP;
use Devel::Chitin::OpTree::PVOP;
use Devel::Chitin::OpTree::METHOP;
use Devel::Chitin::OpTree::BINOP;
use Devel::Chitin::OpTree::LOGOP;
use Devel::Chitin::OpTree::LOGOP_AUX;
use Devel::Chitin::OpTree::LISTOP;
use Devel::Chitin::OpTree::LOOP;
use Devel::Chitin::OpTree::PMOP;
BEGIN {
    if ($^V >= v5.22.0) {
        require Devel::Chitin::OpTree::UNOP_AUX;
    }
}

my %objs_for_op;
sub _obj_for_op {
    my($self, $op) = @_;
    $objs_for_op{$$op};
}
sub build_from_location {
    my($class, $start) = @_;

    my($start_op, $cv) = _determine_start_of($start);

    # adapted from B::walkoptree_slow
    my @parents;
    my $build_walker;
    $build_walker = sub {
        my $op = shift;

        my $self = $class->new(op => $op, cv => $cv);
        $objs_for_op{$$op} = $self;
        weaken $objs_for_op{$$op};

        my @children;
        if ($$op && ($op->flags & B::OPf_KIDS)) {
            unshift(@parents, $self);
            for (my $kid_op = $op->first; $$kid_op; $kid_op = $kid_op->sibling) {
                push @children, $build_walker->($kid_op);
            }
            shift(@parents);
        }

        if (B::class($op) eq 'PMOP'
            and ref($op->pmreplroot)
            and ${$op->pmreplroot}
            and $op->pmreplroot->isa('B::OP')
        ) {
            unshift @parents, $self;
            push @children, $build_walker->($op->pmreplroot);
            shift @parents;
        }

        @$self{'parent','children'} = ($parents[0], \@children);
        $self;
    };

    $build_walker->($start_op);
}

sub _determine_start_of {
    my $start = shift;

    if (reftype($start) eq 'CODE') {
        my $cv = B::svref_2object($start);
        return ($cv->ROOT, $cv);
    }

    unless (blessed($start) and $start->isa('Devel::Chitin::Location')) {
        Carp::croak('build_from_location() requires a coderef or Devel::Chitin::Location as an argument');
    }

    if ($start->package eq 'main' and $start->subroutine eq 'MAIN') {
        return (B::main_root(), B::main_cv);

    } elsif ($start->subroutine =~ m/::__ANON__\[\S+:\d+\]/) {
        Carp::croak(q(Don't know how to handle anonymous subs yet));

    } else {
        my $subname = join('::', $start->package, $start->subroutine);
        my $subref = do { no strict 'refs'; \&$subname };
        my $cv = B::svref_2object($subref);
        return ($cv->ROOT, $cv);
    }
}

sub new {
    my($class, %params) = @_;
    unless (exists $params{op}) {
        Carp::croak(q{'op' is a required parameter of new()});
    }

    my $final_class = _class_for_op($params{op});

    my $self = bless \%params, $final_class;
    $self->_build();
    return $self;
}

sub _class_for_op {
    my $op = shift;
    my $b_class = B::class($op);
    if ($b_class eq 'OP') {
        return __PACKAGE__,
    } elsif ($b_class eq 'UNOP'
             and $op->name eq 'null'
             and $op->flags & B::OPf_KIDS
    ) {
        my $num_children = 0;
        for (my $kid_op = $op->first; $$kid_op; $kid_op = $kid_op->sibling) {
            $num_children++ ;
        }
        if ($num_children > 2) {
            return join('::', __PACKAGE__, 'LISTOP');
        } elsif ($num_children > 1) {
            return join('::', __PACKAGE__, 'BINOP');

        } else {
            return join('::', __PACKAGE__, 'UNOP');
        }
    } else {
        join('::', __PACKAGE__, B::class($op));
    }
}

sub _build { }

sub op { shift->{op} }
sub parent { shift->{parent} }
sub children { shift->{children} }
sub cv { shift->{cv} }
sub root_op {
    my $obj = shift;
    $obj = $obj->parent while ($obj->parent);
    $obj;
}

sub next {
    my $self = shift;
    $self->_obj_for_op($self->op->next);
}

sub sibling {
    my $self = shift;
    $self->_obj_for_op($self->op->sibling);
}

sub walk_preorder {
    my($self, $cb) = @_;
    $_->walk_preorder($cb) foreach (@{ $self->children });
    $cb->($self);
}

sub walk_inorder {
    my($self, $cb) = @_;
    $cb->($self);
    $_->walk_inorder($cb) foreach (@{ $self->children } );
}

sub deparse {
    my $self = shift;
    my $bounce = 'pp_' . $self->op->name;
    $self->$bounce(@_);
}

sub _deparsed_children {
    my $self = shift;
    return grep { $_ }
           map { $_->deparse }
           @{ $self->children };
}

sub is_null {
    return shift->op->name eq 'null';
}

sub pp_null {
    my $self = shift;
    my $bounce = $self->_ex_name;

    if ($bounce eq 'pp_null') {
        my $children = $self->children;
        if (@$children == 2
            and $self->first->is_scalar_container
            and $self->last->op->name eq 'readline'
        ) {
            # not sure why this gets special-cased...
            $self->Devel::Chitin::OpTree::BINOP::pp_sassign(is_swapped => 1);

        } elsif (@$children == 1) {
            $children->[0]->deparse(@_);

        } else {
            ";\n"   # maybe a COP that got optimized away?
        }

    } else {
        $self->$bounce(@_);
    }
}

# These are nextstate/dbstate that got optimized away to null
*pp_nextstate = \&Devel::Chitin::OpTree::COP::pp_nextstate;
*pp_dbstate = \&Devel::Chitin::OpTree::COP::pp_dbstate;

sub pp_padsv {
    my $self = shift;
    # These are 'my' variables.  We're omitting the 'my' because
    # that happens at compile time
    $self->_padname_sv->PV;
}
*pp_padav = \&pp_padsv;
*pp_padhv = \&pp_padsv;

sub pp_aelemfast_lex {
    my $self = shift;
    my $list_name = substr($self->pp_padav, 1); # remove the sigil
    "\$${list_name}[" . $self->op->private . ']';
}
*pp_aelemfast = \&pp_aelemfast_lex;

sub pp_padrange {
    my $self = shift;
    # These are 'my' variables.  We're omitting the 'my' because
    # that happens at compile time
    $self->_padname_sv->PV;
}

sub pp_pushmark {
    my $self = shift;

    die "didn't expect to deparse a pushmark";
}

sub _padname_sv {
    my $self = shift;
    my $targ = shift || $self->op->targ;
#    print "in padname_sv\n";
#    print "PADLIST: ",$self->cv->PADLIST,"\n";
#    print "ARRAYelt(0): ",$self->cv->PADLIST->ARRAYelt(0),"\n";
    return $self->cv->PADLIST->ARRAYelt(0)->ARRAYelt( $targ );
}

sub _padval_sv {
    my($self, $idx) = @_;
    return $self->cv->PADLIST->ARRAYelt(1)->ARRAYelt( $idx );
}

sub _gv_name {
    my($self, $gv) = @_;
    my $last_cop = $self->nearest_cop();
    my $curr_package = $last_cop->op->stashpv;
    my $gv_package = $gv->STASH->NAME;

    $curr_package eq $gv_package
        ? $gv->NAME
        : join('::', $gv_package, $gv->NAME);
}

sub _ex_name {
    my $self = shift;
    if ($self->op->name eq 'null') {
        ppname($self->op->targ);
    }
}

sub _sibling_helper {
    my($self, $cb) = @_;
    my $parent = $self->parent;
    return unless $parent;
    my $children = $parent->children;
    return unless ($children and @$children);

    for (my $i = 0; $i < @$children; $i++) {
        if ($children->[$i] eq $self) {
            return $cb->($i, $children);
        }
    }
}
sub pre_siblings {
    my $self = shift;
    $self->_sibling_helper(sub {
        my($i, $children) = @_;
        @$children[0 .. ($i-1)];
    });
}

my %flag_values = (
    WANT_VOID => B::OPf_WANT_VOID,
    WANT_SCALAR => B::OPf_WANT_SCALAR,
    WANT_LIST => B::OPf_WANT_LIST,
    KIDS => B::OPf_KIDS,
    PARENS => B::OPf_PARENS,
    REF => B::OPf_REF,
    MOD => B::OPf_MOD,
    STACKED => B::OPf_STACKED,
    SPECIAL => B::OPf_SPECIAL,
);
sub print_as_tree {
    my $self = shift;
    $self->walk_inorder(sub {
        my $op = shift;
        my($level, $parent) = (0, $op);
        $level++ while($parent = $parent->parent);
        my $name = $op->op->name;
        if ($name eq 'null') {
            $name .= ' (ex-' . $op->_ex_name . ')';
        }

        my $flags = $op->op->flags;
        my @flags = map {
                        $flags & $flag_values{$_}
                            ? $_
                            : ()
                    }
                    qw(WANT_VOID WANT_SCALAR WANT_LIST KIDS PARENS REF MOD STACKED SPECIAL);

        my $file_and_line = $op->class eq 'COP'
                            ? join(':', $op->op->file, $op->op->line)
                            : '';
        printf("%s%s %s (%s) %s 0x%x\n", '  'x$level, $op->class, $name,
                                 join(', ', @flags),
                                 $file_and_line,
                                 refaddr($op));
    });
}

sub class {
    my $self = shift;
    return substr(ref($self), rindex(ref($self), ':')+1);
}

sub nearest_cop {
    my $self = shift;

    my $parent = $self->parent;
    return unless $parent;
    my $siblings = $parent->children;
    return unless $siblings and @$siblings;

    for (my $i = 0; $i < @$siblings; $i++) {
        my $sib = $siblings->[$i];
        if ($sib eq $self) {
            # Didn't find it on one of the siblings already executed, try the parent
            return $parent->nearest_cop();

        } elsif ($sib->class eq 'COP') {
            return $sib;
        }
    }
    return;
}

# The current COP op is stored on scope-like OPs, and on the root op
sub _enter_scope {
    shift->{cur_cop} = undef;
}
sub _leave_scope {
    shift->{cur_cop} = undef;
}
sub _get_cur_cop {
    shift->root_op->{cur_cop};
}
sub _get_cur_cop_in_scope {
    shift->_encompassing_scope_op->{cur_cop};
}
sub _set_cur_cop {
    my $self = shift;
    $self->_encompassing_scope_op->{cur_cop} = $self;
    $self->root_op->{cur_cop} = $self;
};
sub _encompassing_scope_op {
    my $self = my $op = shift;
    for(; $op && !$op->is_scopelike; $op = $op->parent) { }
    $op || $self->root_op;
}

# Usually, rand/srand/pop/shift is an UNOP, but with no args, it's a base-OP
foreach my $d ( [ pp_rand       => 'rand' ],
                [ pp_srand      => 'srand' ],
                [ pp_getppid    => 'getppid' ],
                [ pp_wait       => 'wait' ],
                [ pp_time       => 'time' ],
) {
    my($pp_name, $perl_name) = @$d;
    my $sub = sub {
        my $target = shift->_maybe_targmy;
        "${target}${perl_name}()";
    };
    no strict 'refs';
    *$pp_name = $sub;
}

# Chdir and sleep can be either a UNOP or base-OP
foreach my $d ( [ pp_chdir => 'chdir' ],
                [ pp_sleep => 'sleep' ],
                [ pp_localtime => 'localtime' ],
                [ pp_gmtime => 'gmtime' ],
) {
    my($pp_name, $perl_name) = @$d;
    my $sub = sub {
        my $self = shift;
        my $children = $self->children;
        my $target = $self->_maybe_targmy;
        if (@$children) {
            "${target}${perl_name}(" . $children->[0]->deparse . ')';
        } else {
            "${target}${perl_name}()";
        }
    };
    no strict 'refs';
    *$pp_name = $sub;
}

sub pp_enter { '' }
sub pp_stub { ';' }
sub pp_unstack { '' }
sub pp_undef { 'undef' }
sub pp_wantarray { 'wantarray' }
sub pp_dump { 'dump' }
sub pp_next { 'next' }
sub pp_last { 'last' }
sub pp_redo { 'redo' }
sub pp_const { q('constant optimized away') }

sub pp_pop { 'pop()' }
sub pp_shift { 'shift()' }
sub pp_close { 'close()' }
sub pp_getc { 'getc()' }
sub pp_tell { 'tell()' }
sub pp_enterwrite { 'write()' }
sub pp_fork { 'fork()' }
sub pp_tms { 'times()' }
sub pp_ggrent { 'getgrent()' }
sub pp_eggrent { 'endgrent()' }
sub pp_ehostent { 'endhostent()' }
sub pp_enetent { 'endnetent()' }
sub pp_eservent { 'endservent()' }
sub pp_egrent { 'endgrent()' }
sub pp_epwent { 'endpwent()' }
sub pp_spwent { 'setpwent()' }
sub pp_sgrent { 'setgrent()' }
sub pp_gpwent { 'getpwent()' }
sub pp_getlogin { 'getlogin()' }
sub pp_ghostent { 'gethostent()' }
sub pp_gnetent { 'getnetent()' }
sub pp_gprotoent { 'getprotoent()' }
sub pp_gservent { 'getservent()' }
sub pp_caller { 'caller()' }
sub pp_exit { 'exit()' }
sub pp_umask { 'umask()' }

sub pp_eof {
    shift->op->flags & B::OPf_SPECIAL
        ? 'eof()'
        : 'eof';
}

sub pp_lvavref {
    my $self = shift;
    '(' . $self->_padname_sv->PV . ')';
    #$self->_padname_sv->PV;
}


# file test operators
# These actually show up as UNOPs (usually) and SVOPs (-X _) but it's
# convienent to put them here in the base class
foreach my $a ( [ pp_fteread    => '-r' ],
                [ pp_ftewrite   => '-w' ],
                [ pp_fteexec    => '-x' ],
                [ pp_fteowned   => '-o' ],
                [ pp_ftrread    => '-R' ],
                [ pp_ftrwrite   => '-W' ],
                [ pp_ftrexec    => '-X' ],
                [ pp_ftrowned   => '-O' ],
                [ pp_ftis       => '-e' ],
                [ pp_ftzero     => '-z' ],
                [ pp_ftsize     => '-s' ],
                [ pp_ftfile     => '-f' ],
                [ pp_ftdir      => '-d' ],
                [ pp_ftlink     => '-l' ],
                [ pp_ftpipe     => '-p' ],
                [ pp_ftblk      => '-b' ],
                [ pp_ftsock     => '-S' ],
                [ pp_ftchr      => '-c' ],
                [ pp_fttty      => '-t' ],
                [ pp_ftsuid     => '-u' ],
                [ pp_ftsgid     => '-g' ],
                [ pp_ftsvtx     => '-k' ],
                [ pp_fttext     => '-T' ],
                [ pp_ftbinary   => '-B' ],
                [ pp_ftmtime    => '-M' ],
                [ pp_ftatime    => '-A' ],
                [ pp_ftctime    => '-C' ],
                [ pp_stat       => 'stat' ],
                [ pp_lstat      => 'lstat' ],
) {
    my($pp_name, $perl_name) = @$a;
    my $sub = sub {
        my $self = shift;

        my $fh;
        if ($self->class eq 'UNOP') {
            $fh = $self->children->[0]->deparse;
            $fh = '' if $fh eq '$_';
        } else {
            # It's a test on _: -w _
            $fh = $self->class eq 'SVOP'
                        ? $self->Devel::Chitin::OpTree::SVOP::pp_gv()
                        : $self->Devel::Chitin::OpTree::PADOP::pp_gv();
        }

        if (substr($perl_name, 0, 1) eq '-') {
            # -X type test
            if ($fh) {
                "$perl_name $fh";
            } else {
                $perl_name;
            }
        } else {
            "${perl_name}($fh)";
        }
    };
    no strict 'refs';
    *$pp_name = $sub;
}

# The return values for some OPs is encoded specially, and not through a
# normal sassign
sub _maybe_targmy {
    my $self = shift;

    if ($self->op->private & B::OPpTARGET_MY) {
        $self->_padname_sv->PV . ' = ';
    } else {
        '';
    }
}

# return true for scalar things we can assign to
my %scalar_container_ops = (
    rv2sv => 1,
    pp_rv2sv => 1,
    padsv => 1,
    pp_padsv => 1,
);
sub is_scalar_container {
    my $self = shift;
    my $op_name = $self->is_null
                    ? $self->_ex_name
                    : $self->op->name;
    $scalar_container_ops{$op_name};
}

my %array_container_ops = (
    rv2av => 1,
    pp_rv2av => 1,
    padav => 1,
    pp_padav => 1,
);
sub is_array_container {
    my $self = shift;
    my $op_name = $self->is_null
                    ? $self->_ex_name
                    : $self->op->name;
    $array_container_ops{$op_name};
}

my %scopelike_ops = (
    scope => 1,
    pp_scope => 1,
    leave => 1,
    pp_leave => 1,
    leavetry => 1,
    pp_leavetry => 1,
    leavesub => 1,
    pp_leavesub => 1,
    leaveloop => 1,
    pp_leaveloop => 1,
    entergiven => 1,
    pp_entergiven => 1,
    enterwhile => 1,
    pp_enterwhile => 1,
);
sub is_scopelike {
    my $self = shift;
    my $op_name = $self->is_null
                    ? $self->_ex_name
                    : $self->op->name;
    $scopelike_ops{$op_name};
}

sub is_for_loop {
    my $self = shift;
    # $self, here, is the initialization part of the for-loop, usually an sassign.
    # The sibling is either:
    # 1) a lineseq whose first child is a nextstate and second child is a leaveloop
    # 2) an unstack whose sibling is a leaveloop
    my $sib = $self->sibling;
    return '' if !$sib or $self->isa('Devel::Chitin::OpTree::COP') or $self->is_null;

    my $name = $sib->op->name;
    if ($name eq 'lineseq') {
        my($first ,$second) = @{$sib->children};
        if ($first && ! $first->is_null && $first->isa('Devel::Chitin::OpTree::COP')
            && $second && ! $second->is_null && $second->op->name eq 'leaveloop'
        ) {
            return 1;
        }

    } elsif ($name eq 'unstack' && ($sib->op->flags & B::OPf_SPECIAL)) {
        my $sibsib = $sib->sibling;
        return $sibsib && ! $sibsib->is_null && $sibsib->op->name eq 'leaveloop'
    }
    return ''
}

sub _num_ops_in_for_loop {
    my $self = shift;
    $self->sibling->op->name eq 'unstack' ? 2 : 1;
}

sub _deparse_for_loop {
    my $self = shift;
    # A for-loop is structured like this:
    # nextstate
    # sassign  ( initialization)
    #   ...
    # unstack
    # leaveloop
    #   enterloop
    #   null
    #       and
    #           loop-test
    #               ...
    #           lineseq
    #               leave
    #                   ... (loop body)
    #               loop-continue
    my $init = $self->deparse;
    my $sib = $self->sibling;
    my $leaveloop = $sib->op->name eq 'unstack' ? $sib->sibling : $sib->children->[1];
    my $and_op = $leaveloop->children->[1]->children->[0];
    my $test_op = $and_op->children->[0];
    my $test = $test_op->deparse;
    my $body_op = $and_op->children->[1]->first;
    my $cont_op = $body_op->sibling;
    my $cont = $cont_op->deparse;

    "for ($init; $test; $cont) " . $body_op->deparse;
}

# Return true if this op is the inner list on the right of
# \(@a) = \(@b)
# The optree for this construct looks like:
# aassign
#   ex-list
#     pushmark
#     refgen
#       ex-list <-- Return true here
#         pushmark
#         padav/gv
#   ex-list
#     pushmark
#     ex-refgen
#       ex-list <-- return true here
#           pushmark
#           lvavref
sub is_list_reference_alias {
    my $self = shift;

    return $self->is_null
            && $self->_ex_name eq 'pp_list'
            && $self->parent->op->name eq 'refgen'
            && $self->last->is_array_container;
}

sub _quote_sv {
    my($self, $sv, %params) = @_;
    my $string = $sv->PV;

    my $quote = ($params{skip_quotes} or $self->op->private & B::OPpCONST_BARE)
                    ? ''
                    : q(');
    if ($string =~ m/[\000-\037]/ and !$params{regex_x_flag}) {
        $quote = '"' unless $params{skip_quotes};
        $string = $self->_escape_for_double_quotes($string, %params);
    }

    "${quote}${string}${quote}";
}

my %control_chars = ((map { chr($_) => '\c'.chr($_ + 64) } (1 .. 26)),  # \cA .. \cZ
                     "\c@" => '\c@', "\c[" => '\c[');
my $control_char_rx = join('|', sort keys %control_chars);
sub _escape_for_double_quotes {
    my($self, $str, %params) = @_;

    $str =~ s/\\/\\\\/g;
    $str =~ s/\a/\\a/g;  # alarm
    $str =~ s/\cH/\\b/g unless $params{in_regex}; # backspace
    $str =~ s/\e/\\e/g;  # escape
    $str =~ s/\f/\\f/g;  # form feed
    $str =~ s/\n/\\n/g;  # newline
    $str =~ s/\r/\\r/g;  # CR
    $str =~ s/\t/\\t/g;  # tab
    $str =~ s/"/\\"/g;
    $str =~ s/($control_char_rx)/$control_chars{$1}/ge;
    $str =~ s/([[:^print:]])/sprintf('\x{%x}', ord($1))/ge;

    $str;
}

sub _as_octal {
    my($self, $val) = @_;
    no warnings 'numeric';
    $val + 0 eq $val
        ? sprintf('0%3o', $val)
        : $val;
}

# given an integer and a list of bitwise flag name/value pairs, return
# a string representing the flags or-ed together
sub _deparse_flags {
    my($self, $val, $flags_listref) = @_;

    do {
        no warnings 'numeric';
        unless ($val + 0 eq $val) {
            return $val;  # wasn't a number
        }
    };

    my @flags;
    for (my $i = 0; $i < @$flags_listref; $i += 2) {
        my($flag_name, $flag_value) = @$flags_listref[$i, $i+1];
        if ($val & $flag_value) {
            push @flags, $flag_name;
            $val ^= $flag_value;
        }
    }
    if ($val) {
        # there were unexpected bits set
        push @flags, $val;
    }
    join(' | ', @flags);
}

sub _indent_block_text {
    my($self, $text) = @_;

    my $lines = $text =~ s/\n/\n\t/g;
    if ($lines > 1) {
        $text .= "\n";
    } elsif ($lines == 1 and index($text, "\n") == 0) {
        $text .= "\n";
    } else {
        $text = " $text ";
    }
}

1;
