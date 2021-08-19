/***
    Copyright (c)  1999, 2000 Eazel, Inc.
                   2015-2018 elementary LLC <https://elementary.io>

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU Lesser General Public License version 3, as published
    by the Free Software Foundation, Inc.,.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranties of
    MERCHANTABILITY, SATISFACTORY QUALITY, or FITNESS FOR A PARTICULAR
    PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with this program. If not, see <http://www.gnu.org/licenses/>.

    Authors : John Sullivan <sullivan@eazel.com>
              ammonkey <am.monkeyd@gmail.com>
              Jeremy Wootten <jeremy@elementaryos.org>
***/

namespace Files {

    public class BookmarkList : GLib.Object {

        enum JobType {
            LOAD = 1,
            SAVE = 2
        }

        public unowned GLib.List<Files.Bookmark> list { get; private set; }

        private GLib.FileMonitor monitor;
        private GLib.Queue<JobType> pending_ops;
        private static GLib.File bookmarks_file;
        private Files.CallWhenReady call_when_ready;

        private static BookmarkList instance = null;

        public signal void loaded ();
        public signal void deleted ();

        private BookmarkList () {
            list = new GLib.List<Files.Bookmark> ();
            pending_ops = new GLib.Queue<JobType> ();

            /* Get the user config directory
             * When running under pkexec determine real user from PKEXEC_UID
             */
            string? user_home = PF.UserUtils.get_real_user_home ();
            string config_dir;

            if (user_home != null) {
                config_dir = GLib.Path.build_filename (user_home, ".config");
            } else {
                config_dir = GLib.Environment.get_user_config_dir ();
            }

            /*Check bookmarks file exists and in right place */
            string filename = GLib.Path.build_filename (config_dir,
                                                        "gtk-3.0",
                                                        "bookmarks",
                                                        null);

            var file = GLib.File.new_for_path (filename);
            if (!file.query_exists (null)) {
                /* Bookmarks file does not exist in right place  ... create a new one */
                try {
                    file.get_parent ().make_directory_with_parents (null);
                }
                catch (GLib.Error error) {
                    /* Probably already exists */
                    warning ("Could not create bookmarks directory: %s", error.message);
                }

                try {
                    file.create (GLib.FileCreateFlags.NONE, null);
                }
                catch (GLib.Error error) {
                    critical ("Could not create bookmarks file: %s", error.message);
                }

                /* load existing bookmarks from the old location if it exists */
                var old_filename = GLib.Path.build_filename (GLib.Environment.get_home_dir (),
                                                            ".gtk-bookmarks",
                                                            null);

                var old_file = GLib.File.new_for_path (old_filename);
                if (old_file.query_exists (null)) {
                    /* If there is a legacy bookmark file we copy it to the new location */
                    Files.BookmarkList.bookmarks_file = old_file;
                    load_bookmarks_file ();
                    Files.BookmarkList.bookmarks_file = file;
                } else {
                    /* Else populate the new file with default bookmarks */
                    Files.BookmarkList.bookmarks_file = file;
                    add_special_directories ();
                }

                save_bookmarks_file ();
            } else {
                Files.BookmarkList.bookmarks_file = file;
                load_bookmarks_file ();
            }
        }

        private void add_special_directories () {
            const GLib.UserDirectory[] DIRECTORIES = {
                GLib.UserDirectory.DOCUMENTS,
                GLib.UserDirectory.DOWNLOAD,
                GLib.UserDirectory.MUSIC,
                GLib.UserDirectory.PUBLIC_SHARE,
                GLib.UserDirectory.PICTURES,
                GLib.UserDirectory.TEMPLATES,
                GLib.UserDirectory.VIDEOS
            };

            foreach (GLib.UserDirectory directory in DIRECTORIES) {
                unowned string? dir_s = GLib.Environment.get_user_special_dir (directory);
                if (dir_s != null) {
                    var gof_file = Files.File.get (GLib.File.new_for_path (dir_s));
                    var bookmark = new Bookmark (gof_file);
                    append_internal (bookmark);
                }
            }

            save_bookmarks_file ();
        }

        public static BookmarkList get_instance () {
            if (instance == null) {
                instance = new BookmarkList ();
            }

            return instance;
        }

        public Bookmark? insert_uri (string uri, uint index, string? label = null) {
            var bm = new Bookmark.from_uri (uri, label);
            if (insert_item_internal (bm, index)) {
                save_bookmarks_file ();
                return bm;
            } else {
                return null;
            }
        }

        public bool contains (Files.Bookmark bm) {
            // Only one bookmark per uri allowed
            return (list.find_custom (bm, Files.Bookmark.compare_uris) != null);
        }

        public void rename_item_with_uri (string uri, string new_name) {
            foreach (unowned Files.Bookmark bookmark in list) {
                if (uri == bookmark.uri) {
                    bookmark.label = new_name; // Will cause contents changed signal if different
                    return;
                }
            }
        }

        public void delete_item_with_uri (string uri) {
            foreach (unowned Files.Bookmark bookmark in list) {
                if (uri == bookmark.uri) {
                    stop_monitoring_bookmark (bookmark);
                    list.remove (bookmark);
                    save_bookmarks_file ();
                    return;
                }
            }
        }

        public uint length () {
            return list.length (); // Can be assumed to be limited in length
        }

        public unowned Files.Bookmark? item_at (uint index) {
            assert (index < list.length ()); // Can be assumed to be limited in length
            return list.nth_data (index);
        }

        public void move_item_uri (string uri, int step) {
            int index = 0;
            foreach (unowned Bookmark bm in list) {
                if (uri == bm.uri) {
                    list.remove (bm);
                    list.insert (bm, index + step);
                    save_bookmarks_file ();
                    return;
                }

                index++;
            }
        }

        private bool append_internal (Files.Bookmark bookmark) {
            return insert_item_internal (bookmark, -1);
        }

        private bool insert_item_internal (Files.Bookmark bm, uint index) {
            if (this.contains (bm)) { // Only one bookmark per uri allowed
                return false;
            }
            /* Do not insert bookmark for home or filesystem root (already have builtins) */
            var path = bm.gof_file.location.get_path ();

            if ((path == PF.UserUtils.get_real_user_home () || path == Path.DIR_SEPARATOR_S)) {
                return false;
            }

            list.insert (bm, (int)index);
            start_monitoring_bookmark (bm);
            return true;
        }

        private void load_bookmarks_file () {
            schedule_job (JobType.LOAD);
        }

        private void save_bookmarks_file () {
            schedule_job (JobType.SAVE);
        }

        private void schedule_job (JobType job) {
            if (pending_ops.peek_head () != job) {
                pending_ops.push_head (job);
                if (pending_ops.length == 1) {
                    process_next_op ();
                }
            }
        }

        private void load_bookmarks_file_async () {
            GLib.File file = get_bookmarks_file ();
            file.load_contents_async.begin (null, (obj, res) => {
                try {
                    uint8[] contents;
                    file.load_contents_async.end (res, out contents, null);
                    if (contents != null) {
                        bookmark_list_from_string ((string)contents);
                        this.call_when_ready = new Files.CallWhenReady (get_gof_file_list (), files_ready);
                        loaded (); /* Call now to ensure sidebar is updated even if call_when_ready blocks */
                    }
                } catch (GLib.Error error) {
                    critical ("Error loadinging bookmark file %s", error.message);
                }

                op_processed_call_back ();
            });
        }

        private GLib.List<Files.File> get_gof_file_list () {
            GLib.List<Files.File> files = null;
            list.@foreach ((bm) => {
                files.prepend (bm.gof_file);
            });
            return (owned) files;
        }

        private void files_ready (GLib.List<Files.File> files) {
            /* Sidebar does not use file.info when updating display so do not signal contents changed */
            call_when_ready = null;
        }

        private void bookmark_list_from_string (string contents) {
            list.@foreach (stop_monitoring_bookmark);

            uint count = 0;
            bool result = true;
            string [] lines = contents.split ("\n");
            foreach (string line in lines) {
                if (line[0] == '\0' || line[0] == ' ') {
                    continue; /* ignore blank lines */
                }

                string [] parts = line.split (" ", 2);
                if (parts.length == 2) {
                    result |= append_internal (new Files.Bookmark.from_uri (parts [0], parts [1]));
                } else {
                    result |= append_internal (new Files.Bookmark.from_uri (parts [0]));
                }

                count++;
            }

            list.@foreach (start_monitoring_bookmark);

            if (!result || list.length () > count) {
                /* Save bookmarks if there was a mismatch between the file and the sidebar */
                save_bookmarks_file ();
            }
        }

        private void save_bookmarks_file_async () {
            GLib.File file = get_bookmarks_file ();
            StringBuilder sb = new StringBuilder ();

            list.@foreach ((bookmark) => {
                sb.append (bookmark.uri);
                sb.append (" " + bookmark.label);
                sb.append ("\n");
            });

            file.replace_contents_async.begin (sb.data,
                                               null,
                                               false,
                                               GLib.FileCreateFlags.NONE,
                                               null,
                                               (obj, res) => {
                try {
                    file.replace_contents_async.end (res, null);
                }
                catch (GLib.Error error) {
                    warning ("Error replacing bookmarks file contents %s", error.message);
                } finally {
                    op_processed_call_back ();
                }
            });
        }

        private static GLib.File get_bookmarks_file () {
            return Files.BookmarkList.bookmarks_file;
        }


        private void bookmarks_file_changed_call_back (GLib.File file,
                                                       GLib.File? other_file,
                                                       GLib.FileMonitorEvent event_type) {

            if (event_type == GLib.FileMonitorEvent.CHANGED ||
                event_type == GLib.FileMonitorEvent.CREATED) {

                load_bookmarks_file ();
            }
        }

        private void bookmark_in_list_changed_callback (Files.Bookmark bookmark) {
            save_bookmarks_file ();
        }

        private void bookmark_in_list_to_be_deleted_callback (Files.Bookmark bookmark) {
            delete_item_with_uri (bookmark.uri);
        }

        private void start_monitoring_bookmarks_file () {
            GLib.File file = get_bookmarks_file ();
            try {
                monitor = file.monitor (GLib.FileMonitorFlags.SEND_MOVED, null);
                monitor.set_rate_limit (1000);
                monitor.changed.connect (bookmarks_file_changed_call_back);
            }
            catch (GLib.Error error) {
                warning ("Error starting to monitor bookmarks file: %s", error.message);
            }
        }

        private void stop_monitoring_bookmarks_file () {
            if (monitor == null) {
                return;
            }

            monitor.cancel ();
            monitor.changed.disconnect (bookmarks_file_changed_call_back);
            monitor = null;
        }

        private void start_monitoring_bookmark (Files.Bookmark bookmark) {
            bookmark.contents_changed.connect (bookmark_in_list_changed_callback);
            bookmark.deleted.connect (bookmark_in_list_to_be_deleted_callback);

        }
        private void stop_monitoring_bookmark (Files.Bookmark bookmark) {
            bookmark.contents_changed.disconnect (bookmark_in_list_changed_callback);
            bookmark.deleted.disconnect (bookmark_in_list_to_be_deleted_callback);
        }

        private void process_next_op () {
            stop_monitoring_bookmarks_file ();
            var pending = pending_ops.peek_tail (); // Leave on queue until finished
            /* if job is LOAD then that might cause a save to be required if there are duplicates */
            switch (pending) {
                case JobType.LOAD:
                    load_bookmarks_file_async ();
                    break;
                case JobType.SAVE:
                    save_bookmarks_file_async ();
                    break;
                default:
                    warning ("Invalid booklist operation");
                    op_processed_call_back ();
                    break;
            }
        }

        private void op_processed_call_back () {
            pending_ops.pop_tail ();
            if (!pending_ops.is_empty ()) {
                process_next_op ();
            } else {
                start_monitoring_bookmarks_file ();
            }
        }
    }
}
