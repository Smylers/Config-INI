use strict;
use warnings;
package Config::INI::Writer;
use Mixin::Linewise::Writers;

=head1 NAME

Config::INI::Writer - a subclassable .ini-file emitter

=head1 VERSION

version 0.014

=cut

our $VERSION = '0.014';

=head1 SYNOPSIS

If <$hash> contains:

  {
    '_'  => { admin => 'rjbs' },
    rjbs => {
      awesome => 'yes',
      height  => q{5' 10"},
    },
    mj   => {
      awesome => 'totally',
      height  => '23"',
    },
  }

Then when your program contains:

  Config::INI::Writer->write_file($hash, 'family.ini');

F<family.ini> will contains:

  admin = rjbs

  [rjbs]
  awesome = yes
  height = 5' 10"

  [mj]
  awesome = totally
  height = 23"

=head1 DESCRIPTION

Config::INI::Writer is I<yet another> config module implementing I<yet another>
slightly different take on the undeniably easy to read L<".ini" file
format|Config::INI>.  Its default behavior is quite similar to that of
L<Config::Tiny>, on which it is based.

The chief difference is that Config::INI::Writer is designed to be subclassed
to allow for side-effects and self-reconfiguration to occur during the course
of reading its input.

=head1 METHODS FOR WRITING CONFIG

There are three writer methods, C<write_string>, C<write_file>, and
C<write_handle>.  The first two are implemented in terms of the third.  It
iterates over a collection of data, emitting lines to the filehandle as it
goes.  The lines are generated by events produced by iterating over the data.
Those events are detailed below in the L</METHODS FOR SUBCLASSING> section.

The given data should be a hashref of hashrefs:

  {
    section_name_1 => { prop1 => 'value1', prop2 => 'value2' },
    section_name_2 => ...
  }

...or an arrayref of section name and arrayref pairs:

  [
    section_name_1 => [ prop1 => 'value1', prop2 => 'value2' ],
    section_name_2 => ...
  ]

...or a combination of those:

  [
    section_name_1 => { prop1 => 'value1', prop2 => 'value2' },
    section_name_2 => [ prop3 => 'value3', prop4 => 'value4' ],
    section_name_3 => ...
  ]


All the reader methods throw an exception when they encounter an error.

=head2 write_file

  Config::INI::Writer->write_file($input, $filename);

This method writes out the configuration represented by C<$data> to the file
named by C<$filename>.  If a file by that name exists, it is overwritten.

This method will either succeed or raise an exception.  (Its return value is
not defined.)

=head2 write_string

  my $string = Config::INI::Writer->write_string($input);

This method returns a string containing the INI content describing the given
data.

=head2 write_handle

  Config::INI::Writer->write_handle($input, $handle);

This method writes the data in C<$data> to the IO::Handle-like object in
C<$handle>.  This method should either succeed or throw an exception.

=cut

sub write_handle {
  my ($invocant, $input, $handle) = @_;

  my $self = ref $invocant ? $invocant : $invocant->new;

  $input = $self->preprocess_input($input);

  $self->validate_input($input);

  my $starting_section_name = $self->starting_section;

  SECTION: for (my $i = 0; $i < $#$input; $i += 2) {
    my ($section_name, $section_data) = @$input[ $i, $i + 1 ];

    $self->change_section($section_name);
    $handle->print($self->stringify_section($section_data))
      or Carp::croak "error writing section $section_name: $!";
    $self->finish_section;
  }
}

=head1 METHODS FOR SUBCLASSING

These are the methods you need to understand and possibly change when
subclassing Config::INI::Reader to handle a different format of input.

=head2 preprocess_input

  my $processed_input = $writer->preprocess_input($input_data);

This method is called to ensure that the data given to the C<write_*> methods
are in a canonical form for processing and emitting.  The default
implementation converts hashrefs to arrayrefs and, if the input is a hashref,
moves the L</starting_section> to the beginning of the produced arrayref.

In other words, given:

  {
    section_1 => { a => 1, b => 2 },
    section_2 => { c => 3, c => 4 },
    _         => { d => 5, e => 6 },
  }

This method will return:

  [
    _         => [ d => 5, e => 6 ],
    section_2 => [ c => 3, c => 4 ],
    section_1 => [ a => 1, b => 2 ],
  ]

The only guaranteed ordering when hashes are provided as input is that the
starting section will appear first.

=cut

sub preprocess_input {
  my ($self, $data) = @_;

  my @new_data;

  if (ref $data eq 'HASH') {
    my $starting_section_name = $self->starting_section;

    for my $name (
      $starting_section_name,
      grep { $_ ne $starting_section_name } keys %$data
    ) {
      my $props = $data->{ $name };
      next unless defined $props;
      push @new_data,
        $name => ((ref($props) || '') eq 'HASH') ? [ %$props ] : $props;
    }
  } elsif (ref $data eq 'ARRAY') {
    for (my $i = 0; $i < $#$data; $i += 2) {
      my ($name, $props) = @$data[ $i, $i + 1 ];
      push @new_data, $name, (ref $props eq 'HASH') ? [ %$props ] : $props;
    }
  } else {
    my $class = ref $self;
    Carp::croak "can't output $data via $class";
  }

  return \@new_data;
}

=head2 validate_input

  $writer->validate_input($input);

This method is called on the input data once they've been preprocessed by
C<L</preprocess_input>>.

It ensures that the processed input is structurally sound before beginning to
output it.  For example, it ensures that no property is ever assigned more than
once in a given section.

This method either raises an exception or it doesn't.

=cut

sub validate_input {
  my ($self, $input) = @_;

  my %seen;
  for (my $i = 0; $i < $#$input; $i += 2) {
    my ($name, $props) = @$input[ $i, $i + 1 ];
    $seen{ $name } ||= {};

    Carp::croak "illegal section name '$name'"
      if $name =~ /(?:\n|\s;|^\s|\s$)/;

    for (my $j = 0; $j < $#$props; $j += 2) {
      my $property = $props->[ $j ];
      my $value    = $props->[ $j + 1 ];

      Carp::croak "property name '$property' contains illegal character"
        if $property =~ /(?:\n|\s;|^\s|\s|=$)/;

      Carp::croak "value for $name.$property contains illegal character"
        if defined $value and $value =~ /(?:\n|\s;|^\s|\s$)/;

      if ( $seen{ $name }{ $property }++ ) {
        Carp::croak "multiple assignments found for $name.$property";
      }
    }
  }
}

=head2 change_section

  $writer->change_section($section_name);

This method is called each time a new section is going to be written out.  If
the same section appears twice in a row in the input, this method will still be
called between instances of that section.

In other words, given this input:

  [
    section_1 => [ a => 1 ],
    section_1 => [ b => 2 ],
  ]

C<change_section> will be called twice: once before the first C<section_1> and
once before the second C<section_1>.

=cut

sub change_section {
  my ($self, $section_name) = @_;

  $self->{current_section} = $section_name;
}

=head2 current_section

  $writer->current_section

This method returns the section currently being written out.

=cut

sub current_section {
  my ($self) = @_;
  return $self->{current_section};
}

=head2 finish_section

  $writer->finish_section

This method is called after all of the current section's properties have been
written.

=cut

sub finish_section {
  my ($self) = @_;
  return $self->{did_section}{ $self->current_section }++;
}

=head2 done_sections

  my @names = $writer->done_sections;

This method returns a list of all sections that have been written out and
finished.  The fact that a section name is returned by C<done_sections> does
not mean that there will be no more data for that section, but that at least
one entire set of data has been written out for it.

=cut

sub done_sections {
  my ($self) = @_;
  return keys %{ $self->{did_section} };
}

=head2 stringify_section

  my $string = $writer->stringify_section($props);

This method returns a string assigning all the properties set in the given
data.  This still will include the section header, if needed.  (The only case
in which it is not needed is when the C<L</explicit_starting_header>> method
returns false, no other sections have been done, and the section about to be
stringified is the C<L</starting_section>>.

This method is implemented in terms of C<L</stringify_section_header>> and
C<L</stringify_section_data>>.

=cut

sub stringify_section {
  my ($self, $section_data) = @_;

  my $output = '';

  my $current_section_name  = $self->current_section;
  my $starting_section_name = $self->starting_section;

  unless (
    $starting_section_name
    and $starting_section_name eq $current_section_name
    and ! $self->done_sections
    and ! $self->explicit_starting_header
  ) {
    $output .= $self->stringify_section_header($self->current_section);
  }

  $output .= $self->stringify_section_data($section_data);

  return $output;
}

=head2 stringify_section_data

  my $string = $writer->stringify_section_data($props)

This method returns a string containing a series of lines, each containing a
value assignment for the given properties.

=cut

sub stringify_section_data {
  my ($self, $values) = @_;

  my $output = '';

  for (my $i = 0; $i < $#$values; $i += 2) {
    $output .= $self->stringify_value_assignment(@$values[ $i, $i + 1]);
  }

  return $output;
}

=head2 stringify_value_assignment

  my $string = $writer->stringify_value_assignment($name => $value);

This method returns a string that assigns a value to a named property.  If the
value is undefined, an empty string is returned.

=cut

sub stringify_value_assignment {
  my ($self, $name, $value) = @_;

  return '' unless defined $value;

  return $name . ' = ' . $self->stringify_value($value) . "\n";
}

=head2 stringify_value

  my $string = $writer->stringify_value($value);

This method returns the string that will represent the given value in a
property assignment.

=cut

sub stringify_value {
  my ($self, $value) = @_;

  $value = defined $value ? $value : '';

  return $value;
}

=head2 stringify_section_header

  my $string = $writer->stringify_section_header($section_name);

This method returns the string (a line) that represents the given section name.
Basically, this returns:

  [section_name]

=cut

sub stringify_section_header {
  my ($self, $section_name) = @_;

  my $output  = '';
     $output .= "\n" if $self->done_sections;
     $output .= "[$section_name]\n";

  return $output;
}

=head2 starting_section

This method returns the name of the starting section.  If this section appears
first (as it will, when given a hashref as input) and if
C<L</explicit_starting_header>> returns false, its section header can be
omitted.

=cut

sub starting_section { return '_' }

=head2 explicit_starting_header

If this method returns true (which it does I<not>, by default), then the
section header for the starting section will be emitted, even if it appears
first.

=cut

sub explicit_starting_header { 0 }

=head2 new


  my $reader = Config::INI::Writer->new;

This method returns a new writer.  This generally does not need to be called by
anything but the various C<write_*> methods, which create a writer object only
ephemerally.

=cut

sub new {
  my ($class) = @_;

  my $self = bless { did_section => {} } => $class;

  return $self;
}

=head1 TODO

=over

=item * more tests

=back

=head1 BUGS

Bugs should be reported via the CPAN bug tracker at

L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Config-INI>

For other issues, or commercial enhancement or support, contact the author.

=head1 AUTHOR

Ricardo SIGNES, C<< E<lt>rjbs@cpan.orgE<gt> >>

Originaly derived from L<Config::Tiny>, by Adam Kennedy.  The first pass at
refactoring this code into Config::INI::Writer was performed by Florian
Ragwitz.

=head1 COPYRIGHT

Copyright 2007, Ricardo SIGNES.

This program is free software; you may redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
