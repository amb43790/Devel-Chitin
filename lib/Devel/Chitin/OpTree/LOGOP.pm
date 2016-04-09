package Devel::Chitin::OpTree::LOGOP;
use base 'Devel::Chitin::OpTree::UNOP';

use Devel::Chitin::Version;

use strict;
use warnings;

sub other {
    shift->{children}->[1];
}

sub pp_entertry { '' }

sub pp_regcomp {
    my $self = shift;
    my %params = @_;

    my $rx_op = $self->first;
    my $rx_op_name = $rx_op->op->name;
    $rx_op = $rx_op->first if ($rx_op_name eq 'regcmaybe'
                                or $rx_op_name eq 'regcreset');

    my $deparsed;
    join('', $rx_op->deparse(skip_parens => 1,
                             skip_quotes => 1,
                             skip_concat => 1,
                             join_with => '',
                             %params));
}

sub pp_substcont {
    my $self = shift;
    join('', $self->first->deparse(skip_concat => 1, skip_quotes => 1));
}

# The arrangement looks like this
# mapwhile
#    mapstart
#        padrange
#        null
#            block-or-expr
#                ...
#            list-0
#            list-1
#            ...
sub pp_mapwhile {
    _deparse_map_grep(shift, 'map');
}

sub pp_grepwhile {
    _deparse_map_grep(shift, 'grep');
}

sub _deparse_map_grep {
    my($self, $function) = @_;

    my $mapstart = $self->first;
    my $children = $mapstart->children;

    my $block_or_expr = $mapstart->children->[1]->first;
    $block_or_expr = $block_or_expr->first if $block_or_expr->is_null;

    my @map_params = map { $_->deparse } @$children[2 .. $#$children];
    if ($block_or_expr->is_scopelike) {
        # map { ... } @list
        my $use_parens = (@map_params > 1 or substr($map_params[0], 0, 1) ne '@');

        "${function} " . $block_or_expr->deparse . ' '
            . ($use_parens ? '(' : '')
            . join(', ', @map_params)
            . ($use_parens ? ')' : '');

    } else {
        # map(expr, @list)

        "${function}("
            . $block_or_expr->deparse
            . ', '
            . join(', ', @map_params)
        . ')';
    }
}

sub pp_and {
    my $self = shift;
    my $left = $self->first->deparse;
    my $right = $self->other->deparse;
    if ($self->other->is_scopelike) {
        $left = _format_if_conditional($left);
        $right = _format_if_block($right);
        "if ($left) $right";

    } elsif ($self->parent->is_null
            and $self->parent->pre_siblings
            and ($self->parent->pre_siblings)[-1]->class eq 'COP'
    ) {
        "$right if $left";

    } else {
        "$left && $right";
    }
}

sub pp_or {
    my $self = shift;
    my $right = $self->other->deparse;
    if ($self->other->is_scopelike
        and
        $self->first->is_null
        and
        $self->first->_ex_name eq 'pp_not'
    ) {
        my $left = _format_if_conditional($self->first->first->deparse);
        $right = _format_if_block($self->other->deparse);
        "unless ($left) $right";

    } elsif ($self->parent->is_null
            and $self->parent->pre_siblings
            and ($self->parent->pre_siblings)[0]->class eq 'COP'
    ) {
        $self->other->deparse . ' unless ' . $self->first->deparse;

    } else {
        $self->first->deparse . ' || ' . $self->other->deparse;
    }
}

sub pp_dor {
    my $self = shift;
    $self->first->deparse . ' // ' . $self->other->deparse;
}

sub _format_if_conditional {
    my $code = shift;
    if (index($code, ';') == 0) {
        substr($code, 1);
    } else {
        $code;
    }
}

sub _format_if_block {
    my $code = shift;
    if (index($code,"\n") >=0 ) {
        $code =~ s/^{ \n/{\n/;
        $code =~ s/ }$/\n}/;
    } else {
        # make even one-liner blocks indented
        $code =~ s/^{ /{\n\t/;
        $code =~ s/ }$/\n}/;
    }
    $code;
}

sub pp_andassign { _and_or_assign(shift, '&&=') }
sub pp_orassign { _and_or_assign(shift, '||=') }
sub pp_dorassign { _and_or_assign(shift, '//=') }
sub _and_or_assign {
    my($self, $op) = @_;
    my $var = $self->first->deparse;
    my $value = $self->other->first->deparse;  # skip over sassign (other)
    join(' ', $var, $op, $value);
}

sub pp_cond_expr {
    my $self = shift;
    my $children = $self->children;

    my($cond, $true, $false) = @$children;
    my($cond_code, $true_code, $false_code) = map { $_->deparse } ($cond, $true, $false);

    if ($true->is_scopelike and $false->is_scopelike) {
        $true_code = _format_if_block($true_code);
        $false_code = _format_if_block($false_code);
        $cond_code = _format_if_conditional($cond_code);
        "if ($cond_code) $true_code else $false_code";

    } elsif ($true->is_scopelike
            and $false->is_null
            and ( $false->first->op->name eq 'cond_expr' or $false->first->op->name eq 'and' )
    ) {
        $true_code = _format_if_block($true_code);
        $false_code = _format_if_block($false_code);
        $cond_code = _format_if_conditional($cond_code);
        "if ($cond_code) $true_code els$false_code";

    } else {
        $cond->deparse . ' ? ' . $true->deparse . ' : ' . $false->deparse;
    }
}

1;
