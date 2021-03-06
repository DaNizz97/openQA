# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Schema::ResultSet::Screenshots;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

use OpenQA::Utils 'log_debug';

sub populate_images_to_job {
    my ($self, $imgs, $job_id) = @_;

    # insert the symlinks into the DB
    my %ids;
    for my $img (@$imgs) {
        log_debug "creating $img";
        my $dbh = $self->result_source->schema->storage->dbh;
        my $sth = $dbh->prepare(
            'INSERT INTO screenshots (filename, t_created) VALUES(?, now()) ON CONFLICT DO NOTHING RETURNING id');
        $sth->execute($img);
        my $res = $sth->fetchrow_arrayref;
        $ids{$img} = $res ? $res->[0] : $self->find({filename => $img})->id;
    }
    my @data = map { [$_, $job_id] } values %ids;
    $self->result_source->schema->resultset('ScreenshotLinks')->populate([[qw(screenshot_id job_id)], @data]);
}

1;
