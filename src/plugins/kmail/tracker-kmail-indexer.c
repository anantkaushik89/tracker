/* -*- Mode: C; tab-width: 8; indent-tabs-mode: t; c-basic-offset: 8 -*- */
/*
 * Copyright (C) 2008, Nokia
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA  02110-1301, USA.
 *
 * Authors:
 *  Philip Van Hoof <philip@codeminded.be>
 */
 
#include "config.h"

#include <string.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <glib.h>
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <stdlib.h>
#include <stdio.h>

#include <gmime/gmime.h>

#include <libtracker-common/tracker-ontology.h>

#include <libtracker-data/tracker-data-manager.h>
#include <libtracker-data/tracker-data-query.h>
#include <libtracker-data/tracker-data-update.h>

/* This is okay, we run in-process of the indexer: we can access its symbols */
#include <tracker-indexer/tracker-module.h>
#include <tracker-indexer/tracker-push.h>
#include <tracker-indexer/tracker-module-metadata-private.h>

#include "tracker-kmail-indexer.h"

void tracker_push_module_init (TrackerConfig *config);
void tracker_push_module_shutdown (void);

/* These defines/renames are necessary for -glue.h */
#define tracker_kmail_registrar_set tracker_kmail_indexer_set
#define tracker_kmail_registrar_set_many tracker_kmail_indexer_set_many
#define tracker_kmail_registrar_unset_many tracker_kmail_indexer_unset_many
#define tracker_kmail_registrar_unset tracker_kmail_indexer_unset
#define tracker_kmail_registrar_cleanup tracker_kmail_indexer_cleanup
#define dbus_glib_tracker_kmail_indexer_object_info dbus_glib_tracker_kmail_registrar_object_info

#include "tracker-kmail-registrar-glue.h"

/* Based on data/services/email.metadata */


#define METADATA_EMAIL			       TRACKER_NMO_PREFIX "Email"
#define METADATA_MAILBOXDATA_OBJECT	       TRACKER_NMO_PREFIX "MailboxDataObject"

#define METADATA_EMAIL_RECIPIENT	       TRACKER_NMO_PREFIX "to"
#define METADATA_EMAIL_DATE		       TRACKER_NMO_PREFIX "receivedDate"
#define METADATA_EMAIL_SENDER		       TRACKER_NMO_PREFIX "sender"
#define METADATA_EMAIL_SUBJECT		       TRACKER_NMO_PREFIX "subject"
#define METADATA_EMAIL_SENT_TO		       TRACKER_NMO_PREFIX "recipient"
#define METADATA_EMAIL_CC		       TRACKER_NMO_PREFIX "cc"
#if 0
#define METADATA_EMAIL_TEXT		       TRACKER_NMO_PREFIX "Body" 
#endif

#define NIE_DATASOURCE 			       TRACKER_NIE_PREFIX "DataSource"
#define NIE_DATASOURCE_P 		       TRACKER_NIE_PREFIX "dataSource"

#define RDF_TYPE			       TRACKER_RDF_PREFIX "type"

#define METADATA_EMAIL_MESSAGE_HEADER	       TRACKER_NMO_PREFIX "messageHeader"
#define METADATA_EMAIL_MESSAGE_HEADER_NAME     TRACKER_NMO_PREFIX "headerName"
#define METADATA_EMAIL_MESSAGE_HEADER_VALUE    TRACKER_NMO_PREFIX "headerValue"

#define NAO_TAG				       TRACKER_NAO_PREFIX "Tag"
#define NAO_HASTAG			       TRACKER_NAO_PREFIX "hasTag"
#define NAO_PREFLABEL			       TRACKER_NAO_PREFIX "prefLabel"

#define DATASOURCE_URN			       "urn:nepomuk:datasource:4a157cf0-1241-11de-8c30-0800200c9a66"

G_DEFINE_TYPE (TrackerKMailIndexer, tracker_kmail_indexer, G_TYPE_OBJECT)

/* This runs in-process of tracker-indexer */

static GObject *idx_indexer = NULL;


enum {
	PROP_0,
};

void tracker_push_module_init (TrackerConfig *config);
void tracker_push_module_shutdown (void);

static void
tracker_kmail_indexer_finalize (GObject *object)
{
	G_OBJECT_CLASS (tracker_kmail_indexer_parent_class)->finalize (object);
}

static void
tracker_kmail_indexer_set_property (GObject      *object,
					guint         prop_id,
					const GValue *value,
					GParamSpec   *pspec)
{
	switch (prop_id) {
	default:
		G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
		break;
	}
}

static void
tracker_kmail_indexer_get_property (GObject    *object,
					guint       prop_id,
					GValue     *value,
					GParamSpec *pspec)
{
	switch (prop_id) {
	default:
		G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
		break;
	}
}

static void
tracker_kmail_indexer_class_init (TrackerKMailIndexerClass *klass)
{
	GObjectClass *object_class = G_OBJECT_CLASS (klass);

	object_class->finalize = tracker_kmail_indexer_finalize;
	object_class->set_property = tracker_kmail_indexer_set_property;
	object_class->get_property = tracker_kmail_indexer_get_property;
}

static void
tracker_kmail_indexer_init (TrackerKMailIndexer *object)
{
}


static void
perform_set (TrackerKMailIndexer *object, 
	     const gchar *subject, 
	     const GStrv predicates, 
	     const GStrv values)
{
	guint i = 0;

	if (!tracker_data_query_resource_exists (DATASOURCE_URN, NULL, NULL)) {
		tracker_data_insert_statement (DATASOURCE_URN, RDF_TYPE,
					       NIE_DATASOURCE);
	}

	tracker_data_insert_statement (subject, RDF_TYPE,
		                       METADATA_EMAIL);

	tracker_data_insert_statement (subject, RDF_TYPE,
		                       METADATA_MAILBOXDATA_OBJECT);

	tracker_data_insert_statement (subject, NIE_DATASOURCE_P,
		                       DATASOURCE_URN);

	while (predicates [i] != NULL && values[i] != NULL) {

		/* TODO: TRACKER_KMAIL_PREDICATE_IDMD5
		 *       TRACKER_KMAIL_PREDICATE_UID
		 *       TRACKER_KMAIL_PREDICATE_SERNUM
		 *       TRACKER_KMAIL_PREDICATE_SPAM
		 *       TRACKER_KMAIL_PREDICATE_HAM
		 *
		 * I don't have predicates in Tracker's ontology for these. In
		 * Jürg's vstore branch we are working with Nepomuk as ontology-
		 * set. Perhaps when we merge this to that branch that we can 
		 * improve this situation. */

		if (g_strcmp0 (predicates[i], TRACKER_KMAIL_PREDICATE_TAG) == 0) {

			tracker_data_insert_statement (":1", RDF_TYPE,
			                               NAO_TAG);

			tracker_data_insert_statement (":1", 
			                               NAO_PREFLABEL,
			                               values[i]);

			tracker_data_insert_statement (subject, 
			                               NAO_HASTAG, 
			                                ":1");
		}

		if (g_strcmp0 (predicates[i], TRACKER_KMAIL_PREDICATE_SUBJECT) == 0) {
			tracker_data_insert_statement (subject, 
						       METADATA_EMAIL_SUBJECT, 
						       values[i]);
		}

		if (g_strcmp0 (predicates[i], TRACKER_KMAIL_PREDICATE_SENT) == 0) {
			tracker_data_insert_statement (subject,
						       METADATA_EMAIL_DATE, 
						       values[i]);
		}

		if (g_strcmp0 (predicates[i], TRACKER_KMAIL_PREDICATE_FROM) == 0) {
			tracker_data_insert_statement (subject,
						       METADATA_EMAIL_SENDER, 
						       values[i]);
		}

		if (g_strcmp0 (predicates[i], TRACKER_KMAIL_PREDICATE_TO) == 0) {
			tracker_data_insert_statement (subject,
						       METADATA_EMAIL_SENT_TO, 
						       values[i]);
		}

		if (g_strcmp0 (predicates[i], TRACKER_KMAIL_PREDICATE_CC) == 0) {
			tracker_data_insert_statement (subject, 
						       METADATA_EMAIL_CC, 
						       values[i]);
		}

		i++;
	}

}

static void 
perform_unset (TrackerKMailIndexer *object, 
	       const gchar *subject)
{
	tracker_data_delete_resource (subject); 
}

static void
perform_cleanup (TrackerKMailIndexer *object)
{
	GError *error = NULL;

	tracker_data_update_sparql ("DELETE { ?s ?p ?o } WHERE { ?s nie:dataSource <" DATASOURCE_URN "> }", &error);

	if (error) {
		g_warning ("%s", error->message);
		g_error_free (error);
	}
}

static void
set_stored_last_modseq (guint last_modseq)
{
	tracker_data_manager_set_db_option_int ("KMailLastModseq", (gint) last_modseq);
}

void
tracker_kmail_indexer_set (TrackerKMailIndexer *object, 
			   const gchar *subject, 
			   const GStrv predicates,
			   const GStrv values,
			   const guint modseq,
			   DBusGMethodInvocation *context,
			   GError *derror)
{
	dbus_async_return_if_fail (subject != NULL, context);

	if (predicates && values) {

		dbus_async_return_if_fail (g_strv_length (predicates) == 
					   g_strv_length (values), context);

		perform_set (object, subject, predicates, values);
	}

	set_stored_last_modseq (modseq);

	dbus_g_method_return (context);
}

void
tracker_kmail_indexer_set_many (TrackerKMailIndexer *object, 
				const GStrv subjects, 
				const GPtrArray *predicates,
				const GPtrArray *values,
				const guint modseq,
				DBusGMethodInvocation *context,
				GError *derror)
{
	guint len;
	guint i = 0;

	dbus_async_return_if_fail (subjects != NULL, context);
	dbus_async_return_if_fail (predicates != NULL, context);
	dbus_async_return_if_fail (values != NULL, context);

	len = g_strv_length (subjects);

	dbus_async_return_if_fail (len == predicates->len, context);
	dbus_async_return_if_fail (len == values->len, context);

	while (subjects[i] != NULL) {
		GStrv preds = g_ptr_array_index (predicates, i);
		GStrv vals = g_ptr_array_index (values, i);

		perform_set (object, subjects[i], preds, vals);

		i++;
	}

	set_stored_last_modseq (modseq);

	dbus_g_method_return (context);
}

void
tracker_kmail_indexer_unset_many (TrackerKMailIndexer *object, 
				  const GStrv subjects, 
				  const guint modseq,
				  DBusGMethodInvocation *context,
				  GError *derror)
{
	guint i = 0;

	dbus_async_return_if_fail (subjects != NULL, context);

	while (subjects[i] != NULL) {

		perform_unset (object, subjects[i]);

		i++;
	}

	set_stored_last_modseq (modseq);

	dbus_g_method_return (context);
}

void
tracker_kmail_indexer_unset (TrackerKMailIndexer *object, 
			     const gchar *subject, 
			     const guint modseq,
			     DBusGMethodInvocation *context,
			     GError *derror)
{
	dbus_async_return_if_fail (subject != NULL, context);

	perform_unset (object, subject);

	dbus_g_method_return (context);
}

void
tracker_kmail_indexer_cleanup (TrackerKMailIndexer *object, 
			       const guint modseq,
			       DBusGMethodInvocation *context,
			       GError *derror)
{
	perform_cleanup (object);

	set_stored_last_modseq (modseq);

	dbus_g_method_return (context);
}

void
tracker_push_module_init (TrackerConfig *config)
{
	GError *error = NULL;
	DBusGConnection *connection;

	connection = dbus_g_bus_get (DBUS_BUS_SESSION, &error);

	if (!error) {
		idx_indexer = g_object_new (TRACKER_TYPE_KMAIL_INDEXER, NULL);

		dbus_g_object_type_install_info (G_OBJECT_TYPE (idx_indexer), 
						 &dbus_glib_tracker_kmail_indexer_object_info);

		dbus_g_connection_register_g_object (connection, 
						     TRACKER_KMAIL_INDEXER_PATH, 
						     idx_indexer);
	}

	if (error) {
		g_critical ("Can't init DBus for KMail support: %s", error->message);
		g_error_free (error);
	}
}

void
tracker_push_module_shutdown (void)
{
	if (idx_indexer)
		g_object_unref (idx_indexer);
}
