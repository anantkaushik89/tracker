/*
 * Copyright (C) 2009, Nokia
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA  02110-1301, USA.
 *
 * Author: Philip Van Hoof <philip@codeminded.be>
 */

#include "config.h"

#include <string.h>
#include <glib.h>
#include <glib/gstdio.h>

#include <sqlite3.h>

#include <libtracker-data/tracker-ontology.h>
#include <libtracker-data/tracker-ontologies.h>
#include <libtracker-data/tracker-db-manager.h>
#include <libtracker-data/tracker-db-interface-sqlite.h>

#include "tracker-db-backup.h"

#define TRACKER_DB_BACKUP_META_FILENAME_T	"meta-backup.db.tmp"

typedef struct {
	TrackerDBBackupFinished callback;
	GDestroyNotify destroy;
	gpointer user_data;
	GError *error;
	sqlite3_stmt *stmt;
	sqlite3 *db, *backup_temp;
	sqlite3_backup *backup_db;
	gchar *backup_fname;
	int result;
	GFile *destination, *temp;
} BackupInfo;

GQuark
tracker_db_backup_error_quark (void)
{
	return g_quark_from_static_string ("tracker-db-backup-error-quark");
}

static gboolean
perform_callback (gpointer user_data)
{
	BackupInfo *info = user_data;

	if (info->callback) {
		info->callback (info->error, info->user_data);
	}

	return FALSE;
}

static void
backup_info_free (gpointer user_data)
{
	BackupInfo *info = user_data;

	if (info->destination) {
		g_object_unref (info->destination);
	}

	if (info->temp) {
		g_object_unref (info->temp);
	}

	if (info->destroy) {
		info->destroy (info->user_data);
	}

	g_clear_error (&info->error);

	if (info->stmt) {
		sqlite3_finalize (info->stmt);
	}

	if (info->backup_db) {
		sqlite3_backup_finish (info->backup_db);
		info->backup_db = NULL;
	}

	if (info->backup_temp) {
		sqlite3_close (info->backup_temp);
	}

	if (info->db) {
		sqlite3_close (info->db);
	}

	if (info->backup_fname) {
		g_free (info->backup_fname);
	}

	g_free (info);
}


static gboolean
backup_file_step (gpointer user_data)
{
	BackupInfo *info = user_data;
	guint cnt = 0;
	gboolean cont = TRUE;

	while (cont && info->result == SQLITE_OK) {

		info->result = sqlite3_backup_step (info->backup_db, 5);

		switch (info->result) {
			case SQLITE_OK:
			break;

			case SQLITE_ERROR:
			default:
			cont = FALSE;
			break;
		}

		if (cnt > 100) {
			break;
		}

		cnt++;
	}

	return cont;
}

static void
on_backup_temp_finished (gpointer user_data)
{
	BackupInfo *info = user_data;

	if (info->backup_db) {
		sqlite3_backup_finish (info->backup_db);
		info->backup_db = NULL;
	}

	if (info->db) {
		sqlite3_close (info->db);
		info->db = NULL;
	}


	if (!info->error && info->result != SQLITE_DONE) {
		g_set_error (&info->error, TRACKER_DB_BACKUP_ERROR, 
		             TRACKER_DB_BACKUP_ERROR_UNKNOWN,
		             "%s", sqlite3_errmsg (info->backup_temp));
	}

	if (!info->error) {
		g_file_move (info->temp, info->destination,
		             G_FILE_COPY_OVERWRITE,
		             NULL, NULL, NULL,
		             &info->error);
	}

	perform_callback (info);

	backup_info_free (info);

	return;
}

void
tracker_db_backup_save (GFile                   *destination,
                        TrackerDBBackupFinished  callback,
                        gpointer                 user_data,
                        GDestroyNotify           destroy)
{
	const gchar *db_file = tracker_db_manager_get_file (TRACKER_DB_METADATA);
	BackupInfo *info = g_new0 (BackupInfo, 1);
	GFile *parent;

	info->callback = callback;
	info->user_data = user_data;
	info->destroy = destroy;

	parent = g_file_get_parent (destination);
	info->temp = g_file_get_child (parent, TRACKER_DB_BACKUP_META_FILENAME_T);
	info->destination = g_object_ref (destination);
	info->backup_fname = g_file_get_path (info->temp);
	g_object_unref (parent);

	if (sqlite3_open_v2 (db_file, &info->db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
		g_set_error (&info->error, TRACKER_DB_BACKUP_ERROR, TRACKER_DB_BACKUP_ERROR_UNKNOWN,
		             "Could not open sqlite3 database:'%s'", db_file);

		g_idle_add_full (G_PRIORITY_DEFAULT, perform_callback, info, 
		                 backup_info_free);

		return;
	}

	if (sqlite3_open (info->backup_fname, &info->backup_temp) != SQLITE_OK) {
		g_set_error (&info->error, TRACKER_DB_BACKUP_ERROR, TRACKER_DB_BACKUP_ERROR_UNKNOWN,
		             "Could not open sqlite3 database:'%s'", info->backup_fname);

		g_idle_add_full (G_PRIORITY_DEFAULT, perform_callback, info, 
		                 backup_info_free);

		return;
	}

	info->backup_db = sqlite3_backup_init (info->backup_temp, "main", 
	                                       info->db, "main");

	if (!info->backup_db) {
		g_set_error (&info->error, TRACKER_DB_BACKUP_ERROR, TRACKER_DB_BACKUP_ERROR_UNKNOWN,
		             "Unknown error creating backup db: '%s'", info->backup_fname);

		g_idle_add_full (G_PRIORITY_DEFAULT, perform_callback, info, 
		                 backup_info_free);

		return;
	}

	g_idle_add_full (G_PRIORITY_DEFAULT, backup_file_step, info, 
	                 on_backup_temp_finished);
}

