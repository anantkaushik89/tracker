AM_CPPFLAGS =                                          \
	$(BUILD_CFLAGS)                                \
	-I$(top_srcdir)/src                            \
	-I$(top_builddir)/src                          \
	-DSHAREDIR=\""$(datadir)"\"                    \
	-DLOCALEDIR=\""$(localedir)"\"                 \
	-DLIBEXEC_PATH=\""$(libexecdir)"\"             \
	$(TRACKER_MINER_APPS_CFLAGS)

libexec_PROGRAMS = tracker-miner-apps

tracker_miner_apps_SOURCES =                           \
	tracker-main.c                                 \
	tracker-miner-applications.c                   \
	tracker-miner-applications.h

tracker_miner_apps_LDADD =                             \
	$(top_builddir)/src/libtracker-miner/libtracker-miner-@TRACKER_API_VERSION@.la \
	$(top_builddir)/src/libtracker-sparql-backend/libtracker-sparql-@TRACKER_API_VERSION@.la \
	$(top_builddir)/src/libtracker-common/libtracker-common.la \
	$(BUILD_LIBS)                                  \
	$(TRACKER_MINER_APPS_LIBS)

# DBus interfaces (XML files) and services
%.service.in: %.service.in.in
	@sed -e "s|@libexecdir[@]|${libexecdir}|" $< > $@

servicedir = $(DBUS_SERVICES_DIR)
service_DATA = org.freedesktop.Tracker1.Miner.Applications.service

INTLTOOL_SERVICE_RULE='%.service:   %.service.in   $(INTLTOOL_MERGE) $(wildcard $(top_srcdir)/po/*.po) ; $(INTLTOOL_MERGE) $(top_srcdir)/po $< [$]@ -d -u'
@INTLTOOL_SERVICE_RULE@

tracker-miner-apps.service: tracker-miner-apps.service.in Makefile
	@sed -e "s|@libexecdir[@]|${libexecdir}|" $< > $@

systemd_userdir = $(prefix)/lib/systemd/user
systemd_user_DATA = tracker-miner-apps.service

install-data-hook:
	$(MKDIR_P) "$(DESTDIR)$(datadir)/tracker/miners" && \
	$(LN_S) -f "$(servicedir)/$(service_DATA)" \
                   "$(DESTDIR)$(datadir)/tracker/miners/$(service_DATA)"

uninstall-local:
	$(RM) "$(DESTDIR)$(datadir)/tracker/miners/$(service_DATA)" && \
	$(RM) "$(servicedir)/$(service_DATA)"

# Desktop files: First we fix the VERSION and libexecdir
%.desktop.in: %.desktop.in.in
	@sed -e "s|@libexecdir[@]|${libexecdir}|" \
	     -e "s|@VERSION[@]|${VERSION}|" $< > $@

autostartdir = $(sysconfdir)/xdg/autostart
autostart_DATA = tracker-miner-apps.desktop

@INTLTOOL_DESKTOP_RULE@

# Dist / Clean rules for all data
CLEANFILES = \
	$(autostart_DATA) \
	$(autostart_DATA:.desktop=.desktop.in) \
	$(service_DATA) \
	$(service_DATA:.service=.service.in) \
	$(systemd_user_DATA) \
	$(NULL)

EXTRA_DIST = \
	$(autostart_DATA:.desktop=.desktop.in.in) \
	$(service_DATA:.service=.service.in.in) \
	$(systemd_user_DATA:.service=.service.in) \
	$(NULL)
