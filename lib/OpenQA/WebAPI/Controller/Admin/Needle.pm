# Copyright (C) 2015 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Controller::Admin::Needle;
use Mojo::Base 'Mojolicious::Controller';

use Cwd 'realpath';
use OpenQA::Utils;
use OpenQA::ServerSideDataTable;
use Date::Format 'time2str';

sub index {
    my ($self) = @_;

    $self->render('admin/needle/index');
}

sub _translate_days($) {
    my ($days) = @_;
    return time2str('%Y-%m-%d %H:%M:%S', time - $days * 3600 * 24, 'UTC');
}

sub _translate_cond($) {
    my ($cond) = @_;

    if ($cond =~ m/^min(\d+)$/) {
        return {'>=' => _translate_days($1)};
    }
    elsif ($cond =~ m/^max(\d+)$/) {
        return {'<' => _translate_days($1)};
    }
    die "Unknown '$cond'";
}

sub ajax {
    my ($self) = @_;

    my @columns = qw(directory.name filename last_seen_time last_matched_time);

    # conditions for search/filter
    my @filter_conds;
    my $search_value = $self->param('search[value]');
    push(@filter_conds, {filename => {-like => '%' . $search_value . '%'}}) if $search_value;
    my $seen_query = $self->param('last_seen');
    if ($seen_query && $seen_query ne 'none') {
        push(@filter_conds, {last_seen_time => _translate_cond($seen_query)});
    }
    my $match_query = $self->param('last_match');
    if ($match_query && $match_query ne 'none') {
        push(@filter_conds, {last_matched_time => _translate_cond($match_query)});
    }

    OpenQA::ServerSideDataTable::render_response(
        controller        => $self,
        resultset         => 'Needles',
        columns           => \@columns,
        initial_conds     => [{file_present => 1}],
        filter_conds      => \@filter_conds,
        additional_params => {
            prefetch => ['directory'],
            # Required for ordering by those columns and also eases filtering
            join => [qw(directory)],
        },
        prepare_data_function => sub {
            my ($needles) = @_;
            my @data;
            my %modules;
            my %needle_dir_real_paths;

            my $schema = $self->schema;
            while (my $n = $needles->next) {
                my $filename = $n->filename;
                my $hash     = {
                    id        => $n->id,
                    directory => $n->directory->name,
                    filename  => $filename,
                };
                my $needle_dir_path = $n->directory->path;
                my $real_needle_dir_id;

                if ($needle_dir_real_paths{$needle_dir_path}) {
                    my $real_path = $needle_dir_real_paths{$needle_dir_path}->{real_path};
                    $real_needle_dir_id = $needle_dir_real_paths{$needle_dir_path}->{real_path_id}
                      if $real_path && $needle_dir_path ne $real_path;
                }
                else {
                    my $real_path_id         = $n->directory->id;
                    my $needle_dir_real_path = realpath($needle_dir_path);
                    if ($needle_dir_real_path && $needle_dir_real_path ne $needle_dir_path) {
                        my $real_needle_dir
                          = $self->schema->resultset('NeedleDirs')->find({path => $needle_dir_real_path});
                        if ($real_needle_dir) {
                            $real_needle_dir_id = $real_needle_dir->id;
                            $real_path_id       = $real_needle_dir_id;
                        }
                    }
                    $needle_dir_real_paths{$needle_dir_path} = {
                        real_path    => $needle_dir_real_path,
                        real_path_id => $real_path_id,
                    };
                }
                my $real_needle_info;
                $real_needle_info
                  = $schema->resultset('Needles')->find({dir_id => $real_needle_dir_id, filename => $filename})
                  if $real_needle_dir_id;
                $n = $real_needle_info if $real_needle_info;

                $hash->{last_seen}  = $n->last_seen_time    || 'never';
                $hash->{last_match} = $n->last_matched_time || 'never';

                if (my $last_seen_module_id = $n->last_seen_module_id) {
                    $hash->{last_seen_link} = $self->url_for(
                        'admin_needle_module',
                        module_id => $last_seen_module_id,
                        needle_id => $n->id
                    );
                }
                if (my $last_matched_module_id = $n->last_matched_module_id) {
                    $hash->{last_match_link} = $self->url_for(
                        'admin_needle_module',
                        module_id => $last_matched_module_id,
                        needle_id => $n->id
                    );
                }
                push(@data, $hash);
            }
            return \@data;
        },
    );
}

sub module {
    my ($self) = @_;

    my $schema = $self->schema;
    my $module = $schema->resultset('JobModules')->find($self->param('module_id'));
    my $needle = $schema->resultset('Needles')->find($self->param('needle_id'))->name;

    my $index = 1;
    for my $detail (@{$module->details->{results}}) {
        last if $detail->{needle} eq $needle;
        last if grep { $needle eq $_->{name} } @{$detail->{needles} || []};
        $index++;
    }
    $self->redirect_to('step', testid => $module->job_id, moduleid => $module->name(), stepid => $index);
}

sub delete {
    my ($self) = @_;

    $self->gru->enqueue_and_keep_track(
        task_name        => 'delete_needles',
        task_description => 'deleting needles',
        task_args        => {
            needle_ids => $self->every_param('id'),
            user_id    => $self->current_user->id,
        }
    )->then(
        sub {
            my ($result) = @_;

            my $removed_ids = ($result->{removed_ids} //= []);
            $self->emit_event(openqa_needle_delete => {id => $removed_ids}) if (@$removed_ids);
            $self->render(json => $result);
        }
    )->catch(
        sub {
            $self->reply->gru_result(@_);
        });
}

1;
