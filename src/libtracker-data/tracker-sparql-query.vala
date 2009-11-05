/*
 * Copyright (C) 2008-2009, Nokia
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
 */

public errordomain Tracker.SparqlError {
	PARSE,
	UNKNOWN_CLASS,
	UNKNOWN_PROPERTY,
	TYPE,
	INTERNAL,
	UNSUPPORTED
}

public class Tracker.SparqlQuery : Object {
	bool maybe_numeric (PropertyType type) {
		return (type == PropertyType.INTEGER || type == PropertyType.DOUBLE || type == PropertyType.DATETIME || type == PropertyType.UNKNOWN);
	}

	enum VariableState {
		NONE,
		BOUND,
		OPTIONAL
	}

	// Represents a SQL table
	class DataTable : Object {
		public string sql_db_tablename; // as in db schema
		public string sql_query_tablename; // temp. name, generated
		public PredicateVariable predicate_variable;
	}

	abstract class DataBinding : Object {
		public PropertyType data_type;
		public DataTable table;
		public string sql_db_column_name;
	}

	// Represents a mapping of a SPARQL literal to a SQL table and column
	class LiteralBinding : DataBinding {
		public bool is_fts_match;
		public string literal;
	}

	// Represents a mapping of a SPARQL variable to a SQL table and column
	class VariableBinding : DataBinding {
		public weak Variable variable;
		// Specified whether SQL column may contain NULL entries
		public bool maybe_null;
		public bool in_simple_optional;
		public string type;
	}

	class VariableBindingList : Object {
		public List<VariableBinding> list;
	}

	class Variable : Object {
		public string name { get; private set; }
		public string sql_expression { get; private set; }
		public VariableBinding binding;

		public Variable (string name, string sql_identifier) {
			this.name = name;
			this.sql_expression = "\"%s\"".printf (sql_identifier);
		}
	}

	// Represents a variable used as a predicate
	class PredicateVariable : Object {
		public string? subject;
		public string? object;

		public Class? domain;

		public string get_sql_query (SparqlQuery query) throws Error {
			var sql = new StringBuilder ();

			if (subject != null) {
				// single subject
				var subject_id = Data.query_resource_id (subject);

				DBResultSet result_set = null;
				if (subject_id > 0) {
					var iface = DBManager.get_db_interface ();
					var stmt = iface.create_statement ("SELECT (SELECT Uri FROM \"rdfs:Resource\" WHERE ID = \"rdf:type\") FROM \"rdfs:Resource_rdf:type\" WHERE ID = ?");
					stmt.bind_int (0, subject_id);
					result_set = stmt.execute ();
				}

				if (result_set != null) {
					bool first = true;
					do {
						Value value;
						result_set._get_value (0, out value);
						var domain = Ontology.get_class_by_uri (value.get_string ());

						foreach (Property prop in Ontology.get_properties ()) {
							if (prop.domain == domain) {
								if (first) {
									first = false;
								} else {
									sql.append (" UNION ALL ");
								}
								sql.append_printf ("SELECT ID, (SELECT ID FROM \"rdfs:Resource\" WHERE Uri = '%s') AS \"predicate\", ", prop.uri);

								append_expression_as_string (sql, "\"%s\"".printf (prop.name), prop.data_type);

								sql.append (" AS \"object\" FROM ");
								if (prop.multiple_values) {
									sql.append_printf ("\"%s_%s\"", prop.domain.name, prop.name);
								} else {
									sql.append_printf ("\"%s\"", prop.domain.name);
								}

								sql.append (" WHERE ID = ?");

								var binding = new LiteralBinding ();
								binding.literal = subject_id.to_string ();
								binding.data_type = PropertyType.INTEGER;
								query.bindings.append (binding);
							}
						}
					} while (result_set.iter_next ());
				} else {
					/* no match */
					sql.append ("SELECT NULL AS ID, NULL AS \"predicate\", NULL AS \"object\"");
				}
			} else if (object != null) {
				// single object
				var object_id = Data.query_resource_id (object);

				var iface = DBManager.get_db_interface ();
				var stmt = iface.create_statement ("SELECT (SELECT Uri FROM \"rdfs:Resource\" WHERE ID = \"rdf:type\") FROM \"rdfs:Resource_rdf:type\" WHERE ID = ?");
				stmt.bind_int (0, object_id);
				var result_set = stmt.execute ();

				bool first = true;
				if (result_set != null) {
					do {
						Value value;
						result_set._get_value (0, out value);
						var range = Ontology.get_class_by_uri (value.get_string ());

						foreach (Property prop in Ontology.get_properties ()) {
							if (prop.range == range) {
								if (first) {
									first = false;
								} else {
									sql.append (" UNION ALL ");
								}
								sql.append_printf ("SELECT ID, (SELECT ID FROM \"rdfs:Resource\" WHERE Uri = '%s') AS \"predicate\", ", prop.uri);

								append_expression_as_string (sql, "\"%s\"".printf (prop.name), prop.data_type);

								sql.append (" AS \"object\" FROM ");
								if (prop.multiple_values) {
									sql.append_printf ("\"%s_%s\"", prop.domain.name, prop.name);
								} else {
									sql.append_printf ("\"%s\"", prop.domain.name);
								}
							}
						}
					} while (result_set.iter_next ());
				} else {
					/* no match */
					sql.append ("SELECT NULL AS ID, NULL AS \"predicate\", NULL AS \"object\"");
				}
			} else if (domain != null) {
				// any subject, predicates limited to a specific domain
				bool first = true;
				foreach (Property prop in Ontology.get_properties ()) {
					if (prop.domain == domain) {
						if (first) {
							first = false;
						} else {
							sql.append (" UNION ALL ");
						}
						sql.append_printf ("SELECT ID, (SELECT ID FROM \"rdfs:Resource\" WHERE Uri = '%s') AS \"predicate\", ", prop.uri);

						append_expression_as_string (sql, "\"%s\"".printf (prop.name), prop.data_type);

						sql.append (" AS \"object\" FROM ");
						if (prop.multiple_values) {
							sql.append_printf ("\"%s_%s\"", prop.domain.name, prop.name);
						} else {
							sql.append_printf ("\"%s\"", prop.domain.name);
						}
					}
				}
			} else {
				// UNION over all properties would exceed SQLite limits
				throw query.get_internal_error ("Unrestricted predicate variables not supported");
			}
			return sql.str;
		}
	}

	SparqlScanner scanner;

	// token buffer
	TokenInfo[] tokens;
	// index of current token in buffer
	int index;
	// number of tokens in buffer
	int size;

	const int BUFFER_SIZE = 32;

	struct TokenInfo {
		public SparqlTokenType type;
		public SourceLocation begin;
		public SourceLocation end;
	}

	const string FN_NS = "http://www.w3.org/2005/xpath-functions#";
	const string FTS_NS = "http://www.tracker-project.org/ontologies/fts#";

	string query_string;
	bool update_extensions;

	string current_graph;
	string current_subject;
	bool current_subject_is_var;
	string current_predicate;
	bool current_predicate_is_var;

	int next_table_index;

	HashTable<string,string> prefix_map;

	// All SQL tables
	List<DataTable> tables;
	HashTable<string,DataTable> table_map;

	// All SPARQL literals
	List<LiteralBinding> bindings;
	List<LiteralBinding> pattern_bindings;

	// All SPARQL variables
	HashTable<string,Variable> var_map;
	List<Variable> pattern_variables;
	HashTable<Variable,VariableBindingList> pattern_var_map;

	// All SPARQL variables within a subgraph pattern (used by UNION)
	HashTable<Variable,int> subgraph_var_set;

	// Variables used as predicates
	HashTable<Variable,PredicateVariable> predicate_variable_map;

	// Keep track of used sql identifiers to avoid using the same for multiple SPARQL variables
	HashTable<string,bool> used_sql_identifiers;

	bool delete_statements;

	int counter;

	int bnodeid = 0;
	// base UUID used for blank nodes
	uchar[] base_uuid;

	public SparqlQuery (string query) {
		tokens = new TokenInfo[BUFFER_SIZE];
		prefix_map = new HashTable<string,string>.full (str_hash, str_equal, g_free, g_free);
		subgraph_var_set = new HashTable<Variable,int>.full (direct_hash, direct_equal, g_object_unref, null);

		base_uuid = new uchar[16];
		uuid_generate (base_uuid);

		this.query_string = query;
	}

	public SparqlQuery.update (string query) {
		this (query);
		this.update_extensions = true;
	}

	string generate_bnodeid (string? user_bnodeid) {
		// user_bnodeid is NULL for anonymous nodes
		if (user_bnodeid == null) {
			return ":%d".printf (++bnodeid);
		} else {
			var checksum = new Checksum (ChecksumType.SHA1);
			// base UUID, unique per file
			checksum.update (base_uuid, 16);
			// node ID
			checksum.update ((uchar[]) user_bnodeid, -1);

			string sha1 = checksum.get_string ();

			// generate name based uuid
			return "urn:uuid:%.8s-%.4s-%.4s-%.4s-%.12s".printf (
				sha1, sha1.offset (8), sha1.offset (12), sha1.offset (16), sha1.offset (20));
		}
	}

	inline bool next () throws SparqlError {
		index = (index + 1) % BUFFER_SIZE;
		size--;
		if (size <= 0) {
			SourceLocation begin, end;
			SparqlTokenType type = scanner.read_token (out begin, out end);
			tokens[index].type = type;
			tokens[index].begin = begin;
			tokens[index].end = end;
			size = 1;
		}
		return (tokens[index].type != SparqlTokenType.EOF);
	}

	inline SparqlTokenType current () {
		return tokens[index].type;
	}

	inline SparqlTokenType last () {
		int last_index = (index + BUFFER_SIZE - 1) % BUFFER_SIZE;
		return tokens[last_index].type;
	}

	inline bool accept (SparqlTokenType type) throws SparqlError {
		if (current () == type) {
			next ();
			return true;
		}
		return false;
	}

	SparqlError get_error (string msg) {
		return new SparqlError.PARSE ("%d.%d: syntax error, %s".printf (tokens[index].begin.line, tokens[index].begin.column, msg));
	}

	SparqlError get_internal_error (string msg) {
		return new SparqlError.INTERNAL ("%d.%d: %s".printf (tokens[index].begin.line, tokens[index].begin.column, msg));
	}

	bool expect (SparqlTokenType type) throws SparqlError {
		if (accept (type)) {
			return true;
		}

		throw get_error ("expected %s".printf (type.to_string ()));
	}

	inline SourceLocation get_location () {
		return tokens[index].begin;
	}

	void set_location (SourceLocation location) {
		scanner.seek (location);
		size = 0;
		index = 0;
		try {
			next ();
		} catch (SparqlError e) {
			// this should never happen as this is the second time we scan this token
			critical ("internal error: next in set_location failed");
		}
	}

	string get_last_string (int strip = 0) {
		int last_index = (index + BUFFER_SIZE - 1) % BUFFER_SIZE;
		return ((string) (tokens[last_index].begin.pos + strip)).ndup ((tokens[last_index].end.pos - tokens[last_index].begin.pos - 2 * strip));
	}

	string escape_sql_string_literal (string literal) {
		return "'%s'".printf (string.joinv ("''", literal.split ("'")));
	}

	unowned Variable get_variable (string name) {
		unowned Variable result = var_map.lookup (name);
		if (result == null) {
			// use lowercase as SQLite is never case sensitive (not conforming to SQL)
			string sql_identifier = "%s_u".printf (name).down ();

			// ensure SQL identifier is unique to avoid conflicts between
			// case sensitive SPARQL and case insensitive SQLite
			for (int i = 1; used_sql_identifiers.lookup (sql_identifier); i++) {
				sql_identifier = "%s_%d_u".printf (name, i).down ();
			}
			used_sql_identifiers.insert (sql_identifier, true);

			var variable = new Variable (name, sql_identifier);
			var_map.insert (name, variable);

			result = variable;
		}
		return result;
	}

	void parse_prologue () throws SparqlError {
		if (accept (SparqlTokenType.BASE)) {
			expect (SparqlTokenType.IRI_REF);
		}
		while (accept (SparqlTokenType.PREFIX)) {
			string ns = "";
			if (accept (SparqlTokenType.PN_PREFIX)) {
				ns = get_last_string ();
			}
			expect (SparqlTokenType.COLON);
			expect (SparqlTokenType.IRI_REF);
			string uri = get_last_string (1);
			prefix_map.insert (ns, uri);
		}
	}

	public DBResultSet? execute () throws Error {
		scanner = new SparqlScanner ((char*) query_string, (long) query_string.size ());
		next ();

		// declare fn prefix for XPath functions
		prefix_map.insert ("fn", FN_NS);

		foreach (Namespace ns in Ontology.get_namespaces ()) {
			prefix_map.insert (ns.prefix, ns.uri);
		}

		parse_prologue ();

		if (!update_extensions) {
			switch (current ()) {
			case SparqlTokenType.SELECT:
				return execute_select ();
			case SparqlTokenType.CONSTRUCT:
				throw get_internal_error ("CONSTRUCT is not supported");
			case SparqlTokenType.DESCRIBE:
				throw get_internal_error ("DESCRIBE is not supported");
			case SparqlTokenType.ASK:
				return execute_ask ();
			case SparqlTokenType.INSERT:
			case SparqlTokenType.DELETE:
			case SparqlTokenType.DROP:
				throw get_error ("INSERT and DELETE are not supported in query mode");
			default:
				throw get_error ("expected SELECT or ASK");
			}
		} else {
			// SPARQL update supports multiple operations in a single query

			while (current () != SparqlTokenType.EOF) {
				switch (current ()) {
				case SparqlTokenType.INSERT:
					execute_insert ();
					break;
				case SparqlTokenType.DELETE:
					execute_delete ();
					break;
				case SparqlTokenType.DROP:
					execute_drop_graph ();
					break;
				case SparqlTokenType.SELECT:
				case SparqlTokenType.CONSTRUCT:
				case SparqlTokenType.DESCRIBE:
				case SparqlTokenType.ASK:
					throw get_error ("SELECT, CONSTRUCT, DESCRIBE, and ASK are not supported in update mode");
				default:
					throw get_error ("expected INSERT or DELETE");
				}
			}

			return null;
		}
	}

	DBResultSet? exec_sql (string sql) throws Error {
		var iface = DBManager.get_db_interface ();
		var stmt = iface.create_statement ("%s", sql);

		// set literals specified in query
		int i = 0;
		foreach (LiteralBinding binding in bindings) {
			if (binding.data_type == PropertyType.BOOLEAN) {
				if (binding.literal == "true" || binding.literal == "1") {
					stmt.bind_int (i, 1);
				} else if (binding.literal == "false" || binding.literal == "0") {
					stmt.bind_int (i, 0);
				} else {
					throw new SparqlError.TYPE ("`%s' is not a valid boolean".printf (binding.literal));
				}
			} else if (binding.data_type == PropertyType.DATETIME) {
				stmt.bind_int (i, string_to_date (binding.literal));
			} else if (binding.data_type == PropertyType.INTEGER) {
				stmt.bind_int (i, binding.literal.to_int ());
			} else {
				stmt.bind_text (i, binding.literal);
			}
			i++;
		}

		return stmt.execute ();
	}

	void skip_select_variables () throws SparqlError {
		while (true) {
			switch (current ()) {
			case SparqlTokenType.FROM:
			case SparqlTokenType.WHERE:
			case SparqlTokenType.OPEN_BRACE:
			case SparqlTokenType.GROUP:
			case SparqlTokenType.ORDER:
			case SparqlTokenType.LIMIT:
			case SparqlTokenType.OFFSET:
			case SparqlTokenType.EOF:
				break;
			default:
				next ();
				continue;
			}
			break;
		}
	}

	void translate_select_expression (StringBuilder sql) throws SparqlError {
		if (accept (SparqlTokenType.COUNT)) {
			sql.append ("COUNT(");
			translate_expression_as_string (sql);
			sql.append (")");
			if (accept (SparqlTokenType.AS)) {
				expect (SparqlTokenType.PN_PREFIX);
			}
		} else if (accept (SparqlTokenType.SUM)) {
			sql.append ("SUM(");
			translate_expression_as_string (sql);
			sql.append (")");
			if (accept (SparqlTokenType.AS)) {
				expect (SparqlTokenType.PN_PREFIX);
			}
		} else if (accept (SparqlTokenType.AVG)) {
			sql.append ("AVG(");
			translate_expression_as_string (sql);
			sql.append (")");
			if (accept (SparqlTokenType.AS)) {
				expect (SparqlTokenType.PN_PREFIX);
			}
		} else if (accept (SparqlTokenType.MIN)) {
			sql.append ("MIN(");
			translate_expression_as_string (sql);
			sql.append (")");
			if (accept (SparqlTokenType.AS)) {
				expect (SparqlTokenType.PN_PREFIX);
			}
		} else if (accept (SparqlTokenType.MAX)) {
			sql.append ("MAX(");
			translate_expression_as_string (sql);
			sql.append (")");
			if (accept (SparqlTokenType.AS)) {
				expect (SparqlTokenType.PN_PREFIX);
			}
		} else if (accept (SparqlTokenType.GROUP_CONCAT)) {
			sql.append ("GROUP_CONCAT(");
			expect (SparqlTokenType.OPEN_PARENS);
			translate_expression_as_string (sql);
			sql.append (", ");
			expect (SparqlTokenType.COMMA);
			sql.append (escape_sql_string_literal (parse_string_literal ()));
			sql.append (")");
			expect (SparqlTokenType.CLOSE_PARENS);
			if (accept (SparqlTokenType.AS)) {
				expect (SparqlTokenType.PN_PREFIX);
			}
		} else {
			translate_expression_as_string (sql);
		}
	}

	void begin_query () {
		var_map = new HashTable<string,Variable>.full (str_hash, str_equal, g_free, g_object_unref);
		predicate_variable_map = new HashTable<Variable,PredicateVariable>.full (direct_hash, direct_equal, g_object_unref, g_object_unref);
		used_sql_identifiers = new HashTable<string,bool>.full (str_hash, str_equal, g_free, null);
	}

	DBResultSet? execute_select () throws Error {
		// SELECT query

		var pattern_sql = new StringBuilder ();
		begin_query ();

		// build SQL
		var sql = new StringBuilder ();
		sql.append ("SELECT ");

		expect (SparqlTokenType.SELECT);

		if (accept (SparqlTokenType.DISTINCT)) {
			sql.append ("DISTINCT ");
		} else if (accept (SparqlTokenType.REDUCED)) {
		}

		// skip select variables (processed later)
		var select_variables_location = get_location ();
		skip_select_variables ();

		if (accept (SparqlTokenType.FROM)) {
			accept (SparqlTokenType.NAMED);
			expect (SparqlTokenType.IRI_REF);
		}

		accept (SparqlTokenType.WHERE);

		translate_group_graph_pattern (pattern_sql);

		// process select variables
		var after_where = get_location ();
		set_location (select_variables_location);

		bool first = true;
		if (accept (SparqlTokenType.STAR)) {
			foreach (var variable in var_map.get_values ()) {
				if (!first) {
					sql.append (", ");
				} else {
					first = false;
				}
				append_expression_as_string (sql, variable.sql_expression, variable.binding.data_type);
			}
		} else {
			while (true) {
				if (!first) {
					sql.append (", ");
				} else {
					first = false;
				}

				translate_select_expression (sql);

				switch (current ()) {
				case SparqlTokenType.FROM:
				case SparqlTokenType.WHERE:
				case SparqlTokenType.OPEN_BRACE:
				case SparqlTokenType.GROUP:
				case SparqlTokenType.ORDER:
				case SparqlTokenType.LIMIT:
				case SparqlTokenType.OFFSET:
				case SparqlTokenType.EOF:
					break;
				default:
					continue;
				}
				break;
			}
		}

		// select from results of WHERE clause
		sql.append (" FROM (");
		sql.append (pattern_sql.str);
		sql.append (")");

		set_location (after_where);

		if (accept (SparqlTokenType.GROUP)) {
			expect (SparqlTokenType.BY);
			sql.append (" GROUP BY ");
			bool first_group = true;
			do {
				if (first_group) {
					first_group = false;
				} else {
					sql.append (", ");
				}
				translate_order_condition (sql);
			} while (current () != SparqlTokenType.ORDER && current () != SparqlTokenType.LIMIT && current () != SparqlTokenType.OFFSET && current () != SparqlTokenType.EOF);
		}

		if (accept (SparqlTokenType.ORDER)) {
			expect (SparqlTokenType.BY);
			sql.append (" ORDER BY ");
			bool first_order = true;
			do {
				if (first_order) {
					first_order = false;
				} else {
					sql.append (", ");
				}
				translate_order_condition (sql);
			} while (current () != SparqlTokenType.LIMIT && current () != SparqlTokenType.OFFSET && current () != SparqlTokenType.EOF);
		}

		int limit = -1;
		int offset = -1;

		if (accept (SparqlTokenType.LIMIT)) {
			expect (SparqlTokenType.INTEGER);
			limit = get_last_string ().to_int ();
			if (accept (SparqlTokenType.OFFSET)) {
				expect (SparqlTokenType.INTEGER);
				offset = get_last_string ().to_int ();
			}
		} else if (accept (SparqlTokenType.OFFSET)) {
			expect (SparqlTokenType.INTEGER);
			offset = get_last_string ().to_int ();
			if (accept (SparqlTokenType.LIMIT)) {
				expect (SparqlTokenType.INTEGER);
				limit = get_last_string ().to_int ();
			}
		}

		// LIMIT and OFFSET
		if (limit >= 0) {
			sql.append (" LIMIT ?");

			var binding = new LiteralBinding ();
			binding.literal = limit.to_string ();
			binding.data_type = PropertyType.INTEGER;
			bindings.append (binding);

			if (offset >= 0) {
				sql.append (" OFFSET ?");

				binding = new LiteralBinding ();
				binding.literal = offset.to_string ();
				binding.data_type = PropertyType.INTEGER;
				bindings.append (binding);
			}
		} else if (offset >= 0) {
			sql.append (" LIMIT -1 OFFSET ?");

			var binding = new LiteralBinding ();
			binding.literal = offset.to_string ();
			binding.data_type = PropertyType.INTEGER;
			bindings.append (binding);
		}

		expect (SparqlTokenType.EOF);

		return exec_sql (sql.str);
	}

	void translate_expression_as_order_condition (StringBuilder sql) throws SparqlError {
		long begin = sql.len;
		if (translate_expression (sql) == PropertyType.RESOURCE) {
			// ID => Uri
			sql.insert (begin, "(SELECT Uri FROM \"rdfs:Resource\" WHERE ID = ");
			sql.append (")");
		}
	}

	void translate_order_condition (StringBuilder sql) throws SparqlError {
		if (accept (SparqlTokenType.ASC)) {
			translate_expression_as_order_condition (sql);
			sql.append (" ASC");
		} else if (accept (SparqlTokenType.DESC)) {
			translate_expression_as_order_condition (sql);
			sql.append (" DESC");
		} else {
			translate_expression_as_order_condition (sql);
		}
	}

	DBResultSet? execute_ask () throws Error {
		// ASK query

		var pattern_sql = new StringBuilder ();
		begin_query ();

		// build SQL
		var sql = new StringBuilder ();
		sql.append ("SELECT ");

		expect (SparqlTokenType.ASK);

		sql.append ("COUNT(1) > 0");

		accept (SparqlTokenType.WHERE);

		translate_group_graph_pattern (pattern_sql);

		// select from results of WHERE clause
		sql.append (" FROM (");
		sql.append (pattern_sql.str);
		sql.append (")");

		return exec_sql (sql.str);
	}

	private void parse_from_or_into_param () throws Error {
		if (accept (SparqlTokenType.IRI_REF)) {
			current_graph = get_last_string (1);
		} else if (accept (SparqlTokenType.PN_PREFIX)) {
			string ns = get_last_string ();
			expect (SparqlTokenType.COLON);
			current_graph = resolve_prefixed_name (ns, get_last_string ().substring (1));
		} else {
			expect (SparqlTokenType.COLON);
			current_graph = resolve_prefixed_name ("", get_last_string ().substring (1));
		}
	}

	void execute_insert () throws Error {
		expect (SparqlTokenType.INSERT);
		if (accept (SparqlTokenType.INTO)) {
			parse_from_or_into_param ();
		} else
			current_graph = null;
		execute_update (false);
	}

	void execute_delete () throws Error {
		expect (SparqlTokenType.DELETE);
		if (accept (SparqlTokenType.FROM)) {
			parse_from_or_into_param ();
		} else
			current_graph = null;
		execute_update (true);
	}

	void execute_update (bool delete_statements) throws Error {
		// INSERT or DELETE

		var pattern_sql = new StringBuilder ();
		begin_query ();

		var sql = new StringBuilder ();

		var template_location = get_location ();
		skip_braces ();

		if (accept (SparqlTokenType.WHERE)) {
			translate_group_graph_pattern (pattern_sql);
		}

		var after_where = get_location ();

		// build SQL
		sql.append ("SELECT ");
		bool first = true;
		foreach (var variable in var_map.get_values ()) {
			if (!first) {
				sql.append (", ");
			} else {
				first = false;
			}

			append_expression_as_string (sql, variable.sql_expression, variable.binding.data_type);
		}

		if (first) {
			sql.append ("1");
		} else {
			// select from results of WHERE clause
			sql.append (" FROM (");
			sql.append (pattern_sql.str);
			sql.append (")");
		}

		var result_set = exec_sql (sql.str);

		this.delete_statements = delete_statements;

		// iterate over all solutions
		if (result_set != null) {
			do {
				// get values of all variables to be bound
				var var_value_map = new HashTable<string,string>.full (str_hash, str_equal, g_free, g_free);
				int var_idx = 0;
				foreach (string var_name in var_map.get_keys ()) {
					Value value;
					result_set._get_value (var_idx++, out value);
					var_value_map.insert (var_name, get_string_for_value (value));
				}

				set_location (template_location);

				// iterate over each triple in the template
				parse_construct_triples_block (var_value_map);
			} while (result_set.iter_next ());
		}

		// reset location to the end of the update
		set_location (after_where);

		// ensure possible WHERE clause in next part gets the correct results
		Data.update_buffer_flush ();
		bindings = null;
	}

	void execute_drop_graph () throws Error {
		expect (SparqlTokenType.DROP);
		expect (SparqlTokenType.GRAPH);

		bool is_var;
		string uri = parse_var_or_term (null, out is_var);

		Data.delete_resource_description (uri, uri);

		// ensure possible WHERE clause in next part gets the correct results
		Data.update_buffer_flush ();
	}

	string resolve_prefixed_name (string prefix, string local_name) throws SparqlError {
		string ns = prefix_map.lookup (prefix);
		if (ns == null) {
			throw get_error ("use of undefined prefix `%s'".printf (prefix));
		}
		return ns + local_name;
	}

	string parse_var_or_term (StringBuilder? sql, out bool is_var) throws SparqlError {
		string result = "";
		is_var = false;
		if (current () == SparqlTokenType.VAR) {
			is_var = true;
			next ();
			result = get_last_string ().substring (1);
		} else if (current () == SparqlTokenType.IRI_REF) {
			next ();
			result = get_last_string (1);
		} else if (current () == SparqlTokenType.PN_PREFIX) {
			// prefixed name with namespace foo:bar
			next ();
			string ns = get_last_string ();
			expect (SparqlTokenType.COLON);
			result = resolve_prefixed_name (ns, get_last_string ().substring (1));
		} else if (current () == SparqlTokenType.COLON) {
			// prefixed name without namespace :bar
			next ();
			result = resolve_prefixed_name ("", get_last_string ().substring (1));
		} else if (accept (SparqlTokenType.BLANK_NODE)) {
			// _:foo
			expect (SparqlTokenType.COLON);
			result = generate_bnodeid (get_last_string ().substring (1));
		} else if (current () == SparqlTokenType.STRING_LITERAL1) {
			result = parse_string_literal ();
		} else if (current () == SparqlTokenType.STRING_LITERAL2) {
			result = parse_string_literal ();
		} else if (current () == SparqlTokenType.STRING_LITERAL_LONG1) {
			result = parse_string_literal ();
		} else if (current () == SparqlTokenType.STRING_LITERAL_LONG2) {
			result = parse_string_literal ();
		} else if (current () == SparqlTokenType.INTEGER) {
			next ();
			result = get_last_string ();
		} else if (current () == SparqlTokenType.DECIMAL) {
			next ();
			result = get_last_string ();
		} else if (current () == SparqlTokenType.DOUBLE) {
			next ();
			result = get_last_string ();
		} else if (current () == SparqlTokenType.TRUE) {
			next ();
			result = "true";
		} else if (current () == SparqlTokenType.FALSE) {
			next ();
			result = "false";
		} else if (current () == SparqlTokenType.OPEN_BRACKET) {
			next ();

			result = generate_bnodeid (null);

			string old_subject = current_subject;
			bool old_subject_is_var = current_subject_is_var;

			current_subject = result;
			current_subject_is_var = true;
			parse_property_list_not_empty (sql);
			expect (SparqlTokenType.CLOSE_BRACKET);

			current_subject = old_subject;
			current_subject_is_var = old_subject_is_var;

			is_var = true;
		} else {
			throw get_error ("expected variable or term");
		}
		return result;
	}

	void parse_object_list (StringBuilder sql, bool in_simple_optional = false) throws SparqlError {
		while (true) {
			parse_object (sql, in_simple_optional);
			if (accept (SparqlTokenType.COMMA)) {
				continue;
			}
			break;
		}
	}

	void parse_property_list_not_empty (StringBuilder sql, bool in_simple_optional = false) throws SparqlError {
		while (true) {
			var old_predicate = current_predicate;
			var old_predicate_is_var = current_predicate_is_var;

			current_predicate = null;
			current_predicate_is_var = false;
			if (current () == SparqlTokenType.VAR) {
				current_predicate_is_var = true;
				next ();
				current_predicate = get_last_string ().substring (1);
			} else if (current () == SparqlTokenType.IRI_REF) {
				next ();
				current_predicate = get_last_string (1);
			} else if (current () == SparqlTokenType.PN_PREFIX) {
				next ();
				string ns = get_last_string ();
				expect (SparqlTokenType.COLON);
				current_predicate = resolve_prefixed_name (ns, get_last_string ().substring (1));
			} else if (current () == SparqlTokenType.COLON) {
				next ();
				current_predicate = resolve_prefixed_name ("", get_last_string ().substring (1));
			} else if (current () == SparqlTokenType.A) {
				next ();
				current_predicate = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type";
			} else {
				throw get_error ("expected non-empty property list");
			}
			parse_object_list (sql, in_simple_optional);

			current_predicate = old_predicate;
			current_predicate_is_var = old_predicate_is_var;

			if (accept (SparqlTokenType.SEMICOLON)) {
				if (current () == SparqlTokenType.DOT) {
					// semicolon before dot is allowed in both, SPARQL and Turtle
					break;
				}
				continue;
			}
			break;
		}
	}

	void translate_bound_call (StringBuilder sql) throws SparqlError {
		expect (SparqlTokenType.BOUND);
		expect (SparqlTokenType.OPEN_PARENS);
		sql.append ("(");
		translate_expression (sql);
		sql.append (" IS NOT NULL)");
		expect (SparqlTokenType.CLOSE_PARENS);
	}

	void translate_regex (StringBuilder sql) throws SparqlError {
		expect (SparqlTokenType.REGEX);
		expect (SparqlTokenType.OPEN_PARENS);
		sql.append ("SparqlRegex(");
		translate_expression (sql);
		sql.append (", ");
		expect (SparqlTokenType.COMMA);
		translate_expression (sql);
		sql.append (", ");
		if (accept (SparqlTokenType.COMMA)) {
			translate_expression (sql);
		} else {
			sql.append ("''");
		}
		sql.append (")");
		expect (SparqlTokenType.CLOSE_PARENS);
	}

	void append_expression_as_string (StringBuilder sql, string expression, PropertyType type) {
		long begin = sql.len;
		sql.append (expression);
		convert_expression_to_string (sql, type, begin);
	}

	void convert_expression_to_string (StringBuilder sql, PropertyType type, long begin) {
		switch (type) {
		case PropertyType.STRING:
		case PropertyType.INTEGER:
			// nothing to convert
			break;
		case PropertyType.RESOURCE:
			// ID => Uri
			sql.insert (begin, "(SELECT Uri FROM \"rdfs:Resource\" WHERE ID = ");
			sql.append (")");
			break;
		case PropertyType.BOOLEAN:
			// 0/1 => false/true
			sql.insert (begin, "CASE ");
			sql.append (" WHEN 1 THEN 'true' WHEN 0 THEN 'false' ELSE NULL END");
			break;
		case PropertyType.DATETIME:
			// ISO 8601 format
			sql.insert (begin, "strftime (\"%Y-%m-%dT%H:%M:%SZ\", ");
			sql.append (", \"unixepoch\")");
			break;
		default:
			// let sqlite convert the expression to string
			sql.insert (begin, "CAST (");
			sql.append (" AS TEXT)");
			break;
		}
	}

	void translate_expression_as_string (StringBuilder sql) throws SparqlError {
		switch (current ()) {
		case SparqlTokenType.IRI_REF:
		case SparqlTokenType.PN_PREFIX:
		case SparqlTokenType.COLON:
			// handle IRI literals separately as it wouldn't work for unknown IRIs otherwise
			var binding = new LiteralBinding ();
			bool is_var;
			binding.literal = parse_var_or_term (null, out is_var);
			if (accept (SparqlTokenType.OPEN_PARENS)) {
				// function call
				long begin = sql.len;
				var type = translate_function (sql, binding.literal);
				expect (SparqlTokenType.CLOSE_PARENS);
				if (accept (SparqlTokenType.AS)) {
					expect (SparqlTokenType.PN_PREFIX);
				}
				convert_expression_to_string (sql, type, begin);
			} else {
				sql.append ("?");
				bindings.append (binding);
			}
			break;
		default:
			long begin = sql.len;
			var type = translate_expression (sql);
			convert_expression_to_string (sql, type, begin);
			break;
		}
	}

	void translate_str (StringBuilder sql) throws SparqlError {
		expect (SparqlTokenType.STR);
		expect (SparqlTokenType.OPEN_PARENS);

		translate_expression_as_string (sql);

		expect (SparqlTokenType.CLOSE_PARENS);
	}

	void translate_isuri (StringBuilder sql) throws SparqlError {
		if (!accept (SparqlTokenType.ISURI)) {
			expect (SparqlTokenType.ISIRI);
		}

		expect (SparqlTokenType.OPEN_PARENS);

		sql.append ("?");
		var new_binding = new LiteralBinding ();
		new_binding.data_type = PropertyType.INTEGER;

		if (current() == SparqlTokenType.IRI_REF) {
			new_binding.literal = "1";
			next ();
		} else if (translate_expression (new StringBuilder ()) == PropertyType.RESOURCE) { 
			new_binding.literal = "1";
		} else {
			new_binding.literal = "0";
		}

		bindings.append (new_binding);

		expect (SparqlTokenType.CLOSE_PARENS);
	}

	void translate_datatype (StringBuilder sql) throws SparqlError {
		expect (SparqlTokenType.DATATYPE);
		expect (SparqlTokenType.OPEN_PARENS);

		if (accept (SparqlTokenType.VAR)) {
			string variable_name = get_last_string().substring(1);
			var variable = get_variable (variable_name);

			if (variable.binding == null) {
				throw get_error ("`%s' is not a valid variable".printf (variable.name));
			}

			if (variable.binding.data_type == PropertyType.RESOURCE || variable.binding.type == null) {
				throw get_error ("Invalid FILTER");
			}

			sql.append ("(SELECT ID FROM \"rdfs:Resource\" WHERE Uri = ?)");

			var new_binding = new LiteralBinding ();
			new_binding.literal = variable.binding.type;
			bindings.append (new_binding);

		} else {
			throw get_error ("Invalid FILTER");
		}

		expect (SparqlTokenType.CLOSE_PARENS);
	}

	PropertyType translate_function (StringBuilder sql, string uri) throws SparqlError {
		if (uri == FN_NS + "contains") {
			// fn:contains('A','B') => 'A' GLOB '*B*'
			sql.append ("(");
			translate_expression_as_string (sql);
			sql.append (" GLOB ");
			expect (SparqlTokenType.COMMA);

			sql.append ("?");
			var binding = new LiteralBinding ();
			binding.literal = "*%s*".printf (parse_string_literal ());
			bindings.append (binding);

			sql.append (")");

			return PropertyType.BOOLEAN;
		} else if (uri == FN_NS + "starts-with") {
			// fn:starts-with('A','B') => 'A' GLOB 'B*'
			sql.append ("(");
			translate_expression_as_string (sql);
			sql.append (" GLOB ");
			expect (SparqlTokenType.COMMA);

			sql.append ("?");
			var binding = new LiteralBinding ();
			binding.literal = "%s*".printf (parse_string_literal ());
			bindings.append (binding);

			sql.append (")");

			return PropertyType.BOOLEAN;
		} else if (uri == FN_NS + "ends-with") {
			// fn:ends-with('A','B') => 'A' GLOB '*B'
			sql.append ("(");
			translate_expression_as_string (sql);
			sql.append (" GLOB ");
			expect (SparqlTokenType.COMMA);

			sql.append ("?");
			var binding = new LiteralBinding ();
			binding.literal = "*%s".printf (parse_string_literal ());
			bindings.append (binding);

			sql.append (")");

			return PropertyType.BOOLEAN;
		} else if (uri == FTS_NS + "rank") {
			bool is_var;
			string v = parse_var_or_term (null, out is_var);
			sql.append_printf ("\"%s_u_rank\"", v);

			return PropertyType.DOUBLE;
		} else if (uri == FTS_NS + "offsets") {
			bool is_var;
			string v = parse_var_or_term (null, out is_var);
			sql.append_printf ("\"%s_u_offsets\"", v);

			return PropertyType.STRING;
		} else {
			// support properties as functions
			var prop = Ontology.get_property_by_uri (uri);
			if (prop == null) {
				throw get_error ("Unknown function");
			}

			if (prop.multiple_values) {
				sql.append_printf ("(SELECT GROUP_CONCAT(\"%s\",',') FROM \"%s_%s\" WHERE ID = ", prop.name, prop.domain.name, prop.name);
				translate_expression (sql);
				sql.append (")");

				return PropertyType.STRING;
			} else {
				sql.append_printf ("(SELECT \"%s\" FROM \"%s\" WHERE ID = ", prop.name, prop.domain.name);
				translate_expression (sql);
				sql.append (")");

				return prop.data_type;
			}
		}
	}

	string parse_string_literal () throws SparqlError {
		next ();
		switch (last ()) {
		case SparqlTokenType.STRING_LITERAL1:
		case SparqlTokenType.STRING_LITERAL2:
			var sb = new StringBuilder ();

			string s = get_last_string (1);
			string* p = s;
			string* end = p + s.size ();
			while ((long) p < (long) end) {
				string* q = Posix.strchr (p, '\\');
				if (q == null) {
					sb.append_len (p, (long) (end - p));
					p = end;
				} else {
					sb.append_len (p, (long) (q - p));
					p = q + 1;
					switch (((char*) p)[0]) {
					case '\'':
					case '"':
					case '\\':
						sb.append_c (((char*) p)[0]);
						break;
					case 'b':
						sb.append_c ('\b');
						break;
					case 'f':
						sb.append_c ('\f');
						break;
					case 'n':
						sb.append_c ('\n');
						break;
					case 'r':
						sb.append_c ('\r');
						break;
					case 't':
						sb.append_c ('\t');
						break;
					}
					p++;
				}
			}

			if (accept (SparqlTokenType.DOUBLE_CIRCUMFLEX)) {
				if (!accept (SparqlTokenType.IRI_REF)) {
					accept (SparqlTokenType.PN_PREFIX);
					expect (SparqlTokenType.COLON);
				}
			}

			return sb.str;
		case SparqlTokenType.STRING_LITERAL_LONG1:
		case SparqlTokenType.STRING_LITERAL_LONG2:
			string result = get_last_string (3);

			if (accept (SparqlTokenType.DOUBLE_CIRCUMFLEX)) {
				if (!accept (SparqlTokenType.IRI_REF)) {
					accept (SparqlTokenType.PN_PREFIX);
					expect (SparqlTokenType.COLON);
				}
			}

			return result;
		default:
			throw get_error ("expected string literal");
		}
	}

	PropertyType translate_primary_expression (StringBuilder sql) throws SparqlError {
		switch (current ()) {
		case SparqlTokenType.OPEN_PARENS:
			return translate_bracketted_expression (sql);
		case SparqlTokenType.IRI_REF:
			next ();

			sql.append ("(SELECT ID FROM \"rdfs:Resource\" WHERE Uri = ?)");

			var binding = new LiteralBinding ();
			binding.literal = get_last_string (1);
			bindings.append (binding);

			return PropertyType.RESOURCE;
		case SparqlTokenType.DECIMAL:
		case SparqlTokenType.DOUBLE:
			next ();

			sql.append ("?");

			var binding = new LiteralBinding ();
			binding.literal = get_last_string ();
			bindings.append (binding);

			return PropertyType.DOUBLE;
		case SparqlTokenType.TRUE:
			next ();

			sql.append ("?");

			var binding = new LiteralBinding ();
			binding.literal = "1";
			binding.data_type = PropertyType.INTEGER;
			bindings.append (binding);

			return PropertyType.BOOLEAN;
		case SparqlTokenType.FALSE:
			next ();

			sql.append ("?");

			var binding = new LiteralBinding ();
			binding.literal = "0";
			binding.data_type = PropertyType.INTEGER;
			bindings.append (binding);

			return PropertyType.BOOLEAN;
		case SparqlTokenType.STRING_LITERAL1:
		case SparqlTokenType.STRING_LITERAL2:
		case SparqlTokenType.STRING_LITERAL_LONG1:
		case SparqlTokenType.STRING_LITERAL_LONG2:
			sql.append ("?");

			var binding = new LiteralBinding ();
			binding.literal = parse_string_literal ();
			bindings.append (binding);

			return PropertyType.STRING;
		case SparqlTokenType.INTEGER:
			next ();

			sql.append ("?");

			var binding = new LiteralBinding ();
			binding.literal = get_last_string ();
			binding.data_type = PropertyType.INTEGER;
			bindings.append (binding);

			return PropertyType.INTEGER;
		case SparqlTokenType.VAR:
			next ();
			string variable_name = get_last_string ().substring (1);
			var variable = get_variable (variable_name);
			sql.append (variable.sql_expression);

			if (variable.binding == null) {
				return PropertyType.UNKNOWN;
			} else {
				return variable.binding.data_type;
			}
		case SparqlTokenType.STR:
			translate_str (sql);
			return PropertyType.STRING;
		case SparqlTokenType.LANG:
			next ();
			sql.append ("''");
			return PropertyType.STRING;
		case SparqlTokenType.LANGMATCHES:
			next ();
			sql.append ("0");
			return PropertyType.BOOLEAN;
		case SparqlTokenType.DATATYPE:
			translate_datatype (sql);
			return PropertyType.RESOURCE;
		case SparqlTokenType.BOUND:
			translate_bound_call (sql);
			return PropertyType.BOOLEAN;
		case SparqlTokenType.SAMETERM:
			next ();
			expect (SparqlTokenType.OPEN_PARENS);
			sql.append ("(");
			translate_expression (sql);
			sql.append (" = ");
			expect (SparqlTokenType.COMMA);
			translate_expression (sql);
			sql.append (")");
			expect (SparqlTokenType.CLOSE_PARENS);
			return PropertyType.BOOLEAN;
		case SparqlTokenType.ISIRI:
		case SparqlTokenType.ISURI:
			translate_isuri (sql);
			return PropertyType.BOOLEAN;
		case SparqlTokenType.ISBLANK:
			next ();
			expect (SparqlTokenType.OPEN_PARENS);
			next ();
			// TODO: support ISBLANK properly
			sql.append ("0");
			expect (SparqlTokenType.CLOSE_PARENS);
			return PropertyType.BOOLEAN;
		case SparqlTokenType.ISLITERAL:
			next ();
			return PropertyType.BOOLEAN;
		case SparqlTokenType.REGEX:
			translate_regex (sql);
			return PropertyType.BOOLEAN;
		case SparqlTokenType.PN_PREFIX:
			next ();
			string ns = get_last_string ();
			expect (SparqlTokenType.COLON);
			string uri = resolve_prefixed_name (ns, get_last_string ().substring (1));
			if (accept (SparqlTokenType.OPEN_PARENS)) {
				// function
				var result = translate_function (sql, uri);
				expect (SparqlTokenType.CLOSE_PARENS);
				return result;
			} else {
				// resource
				sql.append ("(SELECT ID FROM \"rdfs:Resource\" WHERE Uri = ?)");
				var binding = new LiteralBinding ();
				binding.literal = uri;
				bindings.append (binding);
				return PropertyType.RESOURCE;
			}
		case SparqlTokenType.COLON:
			next ();
			sql.append ("(SELECT ID FROM \"rdfs:Resource\" WHERE Uri = ?)");
			var binding = new LiteralBinding ();
			binding.literal = resolve_prefixed_name ("", get_last_string ().substring (1));
			bindings.append (binding);
			return PropertyType.RESOURCE;
		default:
			throw get_error ("expected primary expression");
		}
	}

	PropertyType translate_unary_expression (StringBuilder sql) throws SparqlError {
		if (accept (SparqlTokenType.OP_NEG)) {
			sql.append ("NOT (");
			var optype = translate_primary_expression (sql);
			sql.append (")");
			if (optype != PropertyType.BOOLEAN) {
				throw get_error ("expected boolean expression");
			}
			return PropertyType.BOOLEAN;
		} else if (accept (SparqlTokenType.PLUS)) {
			return translate_primary_expression (sql);
		} else if (accept (SparqlTokenType.MINUS)) {
			sql.append ("-(");
			var optype = translate_primary_expression (sql);
			sql.append (")");
			return optype;
		}
		return translate_primary_expression (sql);
	}

	PropertyType translate_multiplicative_expression (StringBuilder sql) throws SparqlError {
		long begin = sql.len;
		var optype = translate_unary_expression (sql);
		while (true) {
			if (accept (SparqlTokenType.STAR)) {
				if (!maybe_numeric (optype)) {
					throw get_error ("expected numeric operand");
				}
				sql.insert (begin, "(");
				sql.append (" * ");
				if (!maybe_numeric (translate_unary_expression (sql))) {
					throw get_error ("expected numeric operand");
				}
				sql.append (")");
			} else if (accept (SparqlTokenType.DIV)) {
				if (!maybe_numeric (optype)) {
					throw get_error ("expected numeric operand");
				}
				sql.insert (begin, "(");
				sql.append (" / ");
				if (!maybe_numeric (translate_unary_expression (sql))) {
					throw get_error ("expected numeric operand");
				}
				sql.append (")");
			} else {
				break;
			}
		}
		return optype;
	}

	PropertyType translate_additive_expression (StringBuilder sql) throws SparqlError {
		long begin = sql.len;
		var optype = translate_multiplicative_expression (sql);
		while (true) {
			if (accept (SparqlTokenType.PLUS)) {
				if (!maybe_numeric (optype)) {
					throw get_error ("expected numeric operand");
				}
				sql.insert (begin, "(");
				sql.append (" + ");
				if (!maybe_numeric (translate_multiplicative_expression (sql))) {
					throw get_error ("expected numeric operand");
				}
				sql.append (")");
			} else if (accept (SparqlTokenType.MINUS)) {
				if (!maybe_numeric (optype)) {
					throw get_error ("expected numeric operand");
				}
				sql.insert (begin, "(");
				sql.append (" - ");
				if (!maybe_numeric (translate_multiplicative_expression (sql))) {
					throw get_error ("expected numeric operand");
				}
				sql.append (")");
			} else {
				break;
			}
		}
		return optype;
	}

	PropertyType translate_numeric_expression (StringBuilder sql) throws SparqlError {
		return translate_additive_expression (sql);
	}

	PropertyType process_relational_expression (StringBuilder sql, long begin, uint n_bindings, PropertyType op1type, string operator) throws SparqlError {
		sql.insert (begin, "(");
		sql.append (operator);
		var op2type = translate_numeric_expression (sql);
		sql.append (")");
		if ((op1type == PropertyType.DATETIME && op2type == PropertyType.STRING)
		    || (op1type == PropertyType.STRING && op2type == PropertyType.DATETIME)) {
			if (bindings.length () == n_bindings + 1) {
				// trigger string => datetime conversion
				bindings.last ().data.data_type = PropertyType.DATETIME;
			}
		}
		return PropertyType.BOOLEAN;
	}

	PropertyType translate_relational_expression (StringBuilder sql) throws SparqlError {
		long begin = sql.len;
		// TODO: improve performance
		uint n_bindings = bindings.length ();
		var optype = translate_numeric_expression (sql);
		if (accept (SparqlTokenType.OP_GE)) {
			return process_relational_expression (sql, begin, n_bindings, optype, " >= ");
		} else if (accept (SparqlTokenType.OP_EQ)) {
			return process_relational_expression (sql, begin, n_bindings, optype, " = ");
		} else if (accept (SparqlTokenType.OP_NE)) {
			return process_relational_expression (sql, begin, n_bindings, optype, " <> ");
		} else if (accept (SparqlTokenType.OP_LT)) {
			return process_relational_expression (sql, begin, n_bindings, optype, " < ");
		} else if (accept (SparqlTokenType.OP_LE)) {
			return process_relational_expression (sql, begin, n_bindings, optype, " <= ");
		} else if (accept (SparqlTokenType.OP_GT)) {
			return process_relational_expression (sql, begin, n_bindings, optype, " > ");
		}
		return optype;
	}

	PropertyType translate_value_logical (StringBuilder sql) throws SparqlError {
		return translate_relational_expression (sql);
	}

	PropertyType translate_conditional_and_expression (StringBuilder sql) throws SparqlError {
		long begin = sql.len;
		var optype = translate_value_logical (sql);
		while (accept (SparqlTokenType.OP_AND)) {
			if (optype != PropertyType.BOOLEAN) {
				throw get_error ("expected boolean expression");
			}
			sql.insert (begin, "(");
			sql.append (" AND ");
			optype = translate_value_logical (sql);
			sql.append (")");
			if (optype != PropertyType.BOOLEAN) {
				throw get_error ("expected boolean expression");
			}
		}
		return optype;
	}

	PropertyType translate_conditional_or_expression (StringBuilder sql) throws SparqlError {
		long begin = sql.len;
		var optype = translate_conditional_and_expression (sql);
		while (accept (SparqlTokenType.OP_OR)) {
			if (optype != PropertyType.BOOLEAN) {
				throw get_error ("expected boolean expression");
			}
			sql.insert (begin, "(");
			sql.append (" OR ");
			optype = translate_conditional_and_expression (sql);
			sql.append (")");
			if (optype != PropertyType.BOOLEAN) {
				throw get_error ("expected boolean expression");
			}
		}
		return optype;
	}

	PropertyType translate_expression (StringBuilder sql) throws SparqlError {
		return translate_conditional_or_expression (sql);
	}

	PropertyType translate_bracketted_expression (StringBuilder sql) throws SparqlError {
		expect (SparqlTokenType.OPEN_PARENS);
		var optype = translate_expression (sql);
		expect (SparqlTokenType.CLOSE_PARENS);
		return optype;
	}

	PropertyType translate_constraint (StringBuilder sql) throws SparqlError {
		switch (current ()) {
		case SparqlTokenType.STR:
		case SparqlTokenType.LANG:
		case SparqlTokenType.LANGMATCHES:
		case SparqlTokenType.DATATYPE:
		case SparqlTokenType.BOUND:
		case SparqlTokenType.SAMETERM:
		case SparqlTokenType.ISIRI:
		case SparqlTokenType.ISURI:
		case SparqlTokenType.ISBLANK:
		case SparqlTokenType.ISLITERAL:
		case SparqlTokenType.REGEX:
			return translate_primary_expression (sql);
		default:
			return translate_bracketted_expression (sql);
		}
	}

	void translate_filter (StringBuilder sql) throws SparqlError {
		expect (SparqlTokenType.FILTER);
		translate_constraint (sql);
	}

	void skip_filter () throws SparqlError {
		expect (SparqlTokenType.FILTER);

		switch (current ()) {
		case SparqlTokenType.STR:
		case SparqlTokenType.LANG:
		case SparqlTokenType.LANGMATCHES:
		case SparqlTokenType.DATATYPE:
		case SparqlTokenType.BOUND:
		case SparqlTokenType.SAMETERM:
		case SparqlTokenType.ISIRI:
		case SparqlTokenType.ISURI:
		case SparqlTokenType.ISBLANK:
		case SparqlTokenType.ISLITERAL:
		case SparqlTokenType.REGEX:
			next ();
			break;
		default:
			break;
		}

		expect (SparqlTokenType.OPEN_PARENS);
		int n_parens = 1;
		while (n_parens > 0) {
			if (accept (SparqlTokenType.OPEN_PARENS)) {
				n_parens++;
			} else if (accept (SparqlTokenType.CLOSE_PARENS)) {
				n_parens--;
			} else if (current () == SparqlTokenType.EOF) {
				throw get_error ("unexpected end of query, expected )");
			} else {
				// ignore everything else
				next ();
			}
		}
	}

	void skip_braces () throws SparqlError {
		expect (SparqlTokenType.OPEN_BRACE);
		int n_braces = 1;
		while (n_braces > 0) {
			if (accept (SparqlTokenType.OPEN_BRACE)) {
				n_braces++;
			} else if (accept (SparqlTokenType.CLOSE_BRACE)) {
				n_braces--;
			} else if (current () == SparqlTokenType.EOF) {
				throw get_error ("unexpected end of query, expected }");
			} else {
				// ignore everything else
				next ();
			}
		}
	}

	void parse_construct_triples_block (HashTable<string,string> var_value_map) throws SparqlError, DataError {
		expect (SparqlTokenType.OPEN_BRACE);

		if (current () != SparqlTokenType.CLOSE_BRACE) {
			do {
				current_subject = parse_construct_var_or_term (var_value_map);
				parse_construct_property_list_not_empty (var_value_map);
			} while (accept (SparqlTokenType.DOT) && current () != SparqlTokenType.CLOSE_BRACE);
		}

		expect (SparqlTokenType.CLOSE_BRACE);
	}


	string parse_construct_var_or_term (HashTable<string,string> var_value_map) throws SparqlError, DataError {
		string result = "";
		if (current () == SparqlTokenType.VAR) {
			next ();
			result = var_value_map.lookup (get_last_string ().substring (1));
			if (result == null) {
				throw get_error ("undefined variable");
			}
		} else if (current () == SparqlTokenType.IRI_REF) {
			next ();
			result = get_last_string (1);
		} else if (current () == SparqlTokenType.PN_PREFIX) {
			// prefixed name with namespace foo:bar
			next ();
			string ns = get_last_string ();
			expect (SparqlTokenType.COLON);
			result = resolve_prefixed_name (ns, get_last_string ().substring (1));
		} else if (current () == SparqlTokenType.COLON) {
			// prefixed name without namespace :bar
			next ();
			result = resolve_prefixed_name ("", get_last_string ().substring (1));
		} else if (accept (SparqlTokenType.BLANK_NODE)) {
			// _:foo
			expect (SparqlTokenType.COLON);
			result = generate_bnodeid (get_last_string ().substring (1));
		} else if (current () == SparqlTokenType.INTEGER) {
			next ();
			result = get_last_string ();
		} else if (current () == SparqlTokenType.DECIMAL) {
			next ();
			result = get_last_string ();
		} else if (current () == SparqlTokenType.DOUBLE) {
			next ();
			result = get_last_string ();
		} else if (current () == SparqlTokenType.TRUE) {
			next ();
			result = "true";
		} else if (current () == SparqlTokenType.FALSE) {
			next ();
			result = "false";
		} else if (current () == SparqlTokenType.STRING_LITERAL1) {
			result = parse_string_literal ();
		} else if (current () == SparqlTokenType.STRING_LITERAL2) {
			result = parse_string_literal ();
		} else if (current () == SparqlTokenType.STRING_LITERAL_LONG1) {
			result = parse_string_literal ();
		} else if (current () == SparqlTokenType.STRING_LITERAL_LONG2) {
			result = parse_string_literal ();
		} else if (current () == SparqlTokenType.OPEN_BRACKET) {
			next ();

			result = generate_bnodeid (null);

			string old_subject = current_subject;
			bool old_subject_is_var = current_subject_is_var;

			current_subject = result;
			parse_construct_property_list_not_empty (var_value_map);
			expect (SparqlTokenType.CLOSE_BRACKET);

			current_subject = old_subject;
			current_subject_is_var = old_subject_is_var;
		} else {
			throw get_error ("expected variable or term");
		}
		return result;
	}

	void parse_construct_property_list_not_empty (HashTable<string,string> var_value_map) throws SparqlError, DataError {
		while (true) {
			var old_predicate = current_predicate;

			current_predicate = null;
			if (current () == SparqlTokenType.VAR) {
				current_predicate_is_var = true;
				next ();
				current_predicate = var_value_map.lookup (get_last_string ().substring (1));
			} else if (current () == SparqlTokenType.IRI_REF) {
				next ();
				current_predicate = get_last_string (1);
			} else if (current () == SparqlTokenType.PN_PREFIX) {
				next ();
				string ns = get_last_string ();
				expect (SparqlTokenType.COLON);
				current_predicate = resolve_prefixed_name (ns, get_last_string ().substring (1));
			} else if (current () == SparqlTokenType.COLON) {
				next ();
				current_predicate = resolve_prefixed_name ("", get_last_string ().substring (1));
			} else if (current () == SparqlTokenType.A) {
				next ();
				current_predicate = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type";
			} else {
				throw get_error ("expected non-empty property list");
			}
			parse_construct_object_list (var_value_map);

			current_predicate = old_predicate;

			if (accept (SparqlTokenType.SEMICOLON)) {
				continue;
			}
			break;
		}
	}

	void parse_construct_object_list (HashTable<string,string> var_value_map) throws SparqlError, DataError {
		while (true) {
			parse_construct_object (var_value_map);
			if (accept (SparqlTokenType.COMMA)) {
				continue;
			}
			break;
		}
	}

	void parse_construct_object (HashTable<string,string> var_value_map) throws SparqlError, DataError {
		string object = parse_construct_var_or_term (var_value_map);
		if (delete_statements) {
			// delete triple from database
			Data.delete_statement (current_graph, current_subject, current_predicate, object);
		} else {
			// insert triple into database
			Data.insert_statement (current_graph, current_subject, current_predicate, object);
		}
	}

	void start_triples_block (StringBuilder sql) throws SparqlError {
		tables = new List<DataTable> ();
		table_map = new HashTable<string,DataTable>.full (str_hash, str_equal, g_free, g_object_unref);

		pattern_variables = new List<Variable> ();
		pattern_var_map = new HashTable<Variable,VariableBindingList>.full (direct_hash, direct_equal, g_object_unref, g_object_unref);

		pattern_bindings = new List<LiteralBinding> ();

		sql.append ("SELECT ");
	}

	void end_triples_block (StringBuilder sql, ref bool first_where, bool in_group_graph_pattern) throws Error {
		// remove last comma and space
		sql.truncate (sql.len - 2);

		sql.append (" FROM ");
		bool first = true;
		foreach (DataTable table in tables) {
			if (!first) {
				sql.append (", ");
			} else {
				first = false;
			}
			if (table.sql_db_tablename != null) {
				sql.append_printf ("\"%s\"", table.sql_db_tablename);
			} else {
				sql.append_printf ("(%s)", table.predicate_variable.get_sql_query (this));
			}
			sql.append_printf (" AS \"%s\"", table.sql_query_tablename);
		}

		foreach (var variable in pattern_variables) {
			bool maybe_null = true;
			bool in_simple_optional = false;
			string last_name = null;
			foreach (VariableBinding binding in pattern_var_map.lookup (variable).list) {
				string name;
				if (binding.table != null) {
					name = "\"%s\".\"%s\"".printf (binding.table.sql_query_tablename, binding.sql_db_column_name);
				} else {
					// simple optional with inverse functional property
					// always first in loop as variable is required to be unbound
					name = variable.sql_expression;
				}
				if (last_name != null) {
					if (!first_where) {
						sql.append (" AND ");
					} else {
						sql.append (" WHERE ");
						first_where = false;
					}
					sql.append (last_name);
					sql.append (" = ");
					sql.append (name);
				}
				last_name = name;
				if (!binding.maybe_null) {
					maybe_null = false;
				}
				in_simple_optional = binding.in_simple_optional;
			}

			if (maybe_null && !in_simple_optional) {
				// ensure that variable is bound in case it could return NULL in SQL
				// assuming SPARQL variable is not optional
				if (!first_where) {
					sql.append (" AND ");
				} else {
					sql.append (" WHERE ");
					first_where = false;
				}
				sql.append_printf ("%s IS NOT NULL", variable.sql_expression);
			}
		}
		foreach (LiteralBinding binding in pattern_bindings) {
			if (!first_where) {
				sql.append (" AND ");
			} else {
				sql.append (" WHERE ");
				first_where = false;
			}
			sql.append ("\"");
			sql.append (binding.table.sql_query_tablename);
			sql.append ("\".\"");
			sql.append (binding.sql_db_column_name);
			sql.append ("\"");
			if (binding.is_fts_match) {
				// parameters do not work with fts MATCH
				string escaped_literal = string.joinv ("''", binding.literal.split ("'"));
				sql.append_printf (" MATCH '%s'", escaped_literal);
			} else {
				sql.append (" = ");
				if (binding.data_type == PropertyType.RESOURCE) {
					sql.append ("(SELECT ID FROM \"rdfs:Resource\" WHERE Uri = ?)");
				} else {
					sql.append ("?");
				}
				bindings.append (binding);
			}
		}

		if (in_group_graph_pattern) {
			sql.append (")");
		}

		tables = null;
		table_map = null;
		pattern_variables = null;
		pattern_var_map = null;
		pattern_bindings = null;
	}

	void parse_triples (StringBuilder sql, long group_graph_pattern_start, ref bool in_triples_block, ref bool first_where, ref bool in_group_graph_pattern, bool found_simple_optional) throws Error {
		while (true) {
			if (current () != SparqlTokenType.VAR &&
			    current () != SparqlTokenType.IRI_REF &&
			    current () != SparqlTokenType.PN_PREFIX &&
			    current () != SparqlTokenType.COLON &&
			    current () != SparqlTokenType.OPEN_BRACKET) {
				break;
			}
			if (in_triples_block && !in_group_graph_pattern && found_simple_optional) {
				// if there is a regular triple pattern after a simple optional
				// we need to use a separate triple block to avoid possible conflicts
				// due to not using a JOIN for the simple optional
				end_triples_block (sql, ref first_where, in_group_graph_pattern);
				in_triples_block = false;
			}
			if (!in_triples_block) {
				if (in_group_graph_pattern) {
					sql.insert (group_graph_pattern_start, "SELECT * FROM (");
					sql.append (") NATURAL INNER JOIN (");
				}
				in_triples_block = true;
				first_where = true;
				start_triples_block (sql);
			}

			current_subject = parse_var_or_term (sql, out current_subject_is_var);
			parse_property_list_not_empty (sql);

			if (!accept (SparqlTokenType.DOT)) {
				break;
			}
		}
	}

	bool is_simple_optional () {
		var optional_start = get_location ();
		try {
			// check that we have { ?v foo:bar ?o }
			// where ?v is an already BOUND variable
			//       foo:bar is a single-valued property
			//       ?o has not been used before
			// or
			// where ?v has not been used before
			//       foo:bar is an inverse functional property
			//       ?o is an already ?BOUND variable

			expect (SparqlTokenType.OPEN_BRACE);

			// check subject
			if (!accept (SparqlTokenType.VAR)) {
				return false;
			}
			string var_name = get_last_string ().substring (1);
			var left_variable_state = subgraph_var_set.lookup (get_variable (var_name));

			// check predicate
			string predicate;
			if (accept (SparqlTokenType.IRI_REF)) {
				predicate = get_last_string (1);
			} else if (accept (SparqlTokenType.PN_PREFIX)) {
				string ns = get_last_string ();
				expect (SparqlTokenType.COLON);
				predicate = resolve_prefixed_name (ns, get_last_string ().substring (1));
			} else if (accept (SparqlTokenType.COLON)) {
				predicate = resolve_prefixed_name ("", get_last_string ().substring (1));
			} else {
				return false;
			}
			var prop = Ontology.get_property_by_uri (predicate);
			if (prop == null) {
				return false;
			}

			// check object
			if (!accept (SparqlTokenType.VAR)) {
				return false;
			}
			var_name = get_last_string ().substring (1);
			var right_variable_state = subgraph_var_set.lookup (get_variable (var_name));

			// optional .
			accept (SparqlTokenType.DOT);

			// check it is only one triple pattern
			if (!accept (SparqlTokenType.CLOSE_BRACE)) {
				return false;
			}

			if (left_variable_state == VariableState.BOUND && !prop.multiple_values && right_variable_state == 0) {
				// first valid case described in above comment
				return true;
			} else if (left_variable_state == 0 && prop.is_inverse_functional_property && right_variable_state == VariableState.BOUND) {
				// second valid case described in above comment
				return true;
			} else {
				// no match
				return false;
			}
		} catch (SparqlError e) {
			return false;
		} finally {
			// in any case, go back to the start of the optional
			set_location (optional_start);
		}
	}

	void translate_group_graph_pattern (StringBuilder sql) throws Error {
		expect (SparqlTokenType.OPEN_BRACE);

		SourceLocation[] filters = { };

		bool in_triples_block = false;
		bool in_group_graph_pattern = false;
		bool first_where = true;
		bool found_simple_optional = false;
		long group_graph_pattern_start = sql.len;

		// optional TriplesBlock
		parse_triples (sql, group_graph_pattern_start, ref in_triples_block, ref first_where, ref in_group_graph_pattern, found_simple_optional);

		while (true) {
			// check whether we have GraphPatternNotTriples | Filter
			if (accept (SparqlTokenType.OPTIONAL)) {
				if (!in_group_graph_pattern && is_simple_optional ()) {
					// perform join-less optional (like non-optional except for the IS NOT NULL check)
					found_simple_optional = true;
					expect (SparqlTokenType.OPEN_BRACE);

					current_subject = parse_var_or_term (sql, out current_subject_is_var);
					parse_property_list_not_empty (sql, true);

					accept (SparqlTokenType.DOT);
					expect (SparqlTokenType.CLOSE_BRACE);
				} else {
					if (!in_triples_block && !in_group_graph_pattern) {
						// expand { OPTIONAL { ... } } into { { } OPTIONAL { ... } }
						// empty graph pattern => return one result without bound variables
						sql.append ("SELECT 1");
					} else if (in_triples_block) {
						end_triples_block (sql, ref first_where, in_group_graph_pattern);
						in_triples_block = false;
					}
					if (!in_group_graph_pattern) {
						in_group_graph_pattern = true;
					}

					var select = new StringBuilder ("SELECT ");

					int left_index = ++next_table_index;
					int right_index = ++next_table_index;

					sql.append_printf (") AS t%d_g LEFT JOIN (", left_index);

					var old_subgraph_var_set = subgraph_var_set;
					subgraph_var_set = new HashTable<Variable,int>.full (direct_hash, direct_equal, g_object_unref, null);

					translate_group_graph_pattern (sql);

					sql.append_printf (") AS t%d_g", right_index);

					bool first = true;
					bool first_common = true;
					foreach (var v in subgraph_var_set.get_keys ()) {
						if (first) {
							first = false;
						} else {
							select.append (", ");
						}

						var old_state = old_subgraph_var_set.lookup (v);
						if (old_state == 0) {
							// first used in optional part
							old_subgraph_var_set.insert (v, VariableState.OPTIONAL);
							select.append_printf ("t%d_g.%s", right_index, v.sql_expression);
						} else {
							if (first_common) {
								sql.append (" ON ");
								first_common = false;
							} else {
								sql.append (" AND ");
							}

							if (old_state == VariableState.BOUND) {
								// variable definitely bound in non-optional part
								sql.append_printf ("t%d_g.%s = t%d_g.%s", left_index, v.sql_expression, right_index, v.sql_expression);
								select.append_printf ("t%d_g.%s", left_index, v.sql_expression);
							} else if (old_state == VariableState.OPTIONAL) {
								// variable maybe bound in non-optional part
								sql.append_printf ("(t%d_g.%s IS NULL OR t%d_g.%s = t%d_g.%s)", left_index, v.sql_expression, left_index, v.sql_expression, right_index, v.sql_expression);
								select.append_printf ("COALESCE (t%d_g.%s, t%d_g.%s) AS %s", left_index, v.sql_expression, right_index, v.sql_expression, v.sql_expression);
							}
						}
					}
					foreach (var v in old_subgraph_var_set.get_keys ()) {
						if (subgraph_var_set.lookup (v) == 0) {
							// only used in non-optional part
							if (first) {
								first = false;
							} else {
								select.append (", ");
							}

							select.append_printf ("t%d_g.%s", left_index, v.sql_expression);
						}
					}
					if (first) {
						// no variables used at all
						select.append ("1");
					}

					subgraph_var_set = old_subgraph_var_set;

					select.append (" FROM (");
					sql.insert (group_graph_pattern_start, select.str);

					// surround with SELECT * FROM (...) to avoid ambiguous column names
					// in SQL generated for FILTER (triggered by using table aliases for join sources)
					sql.insert (group_graph_pattern_start, "SELECT * FROM (");
					sql.append (")");
				}
			} else if (current () == SparqlTokenType.OPEN_BRACE) {
				if (!in_triples_block && !in_group_graph_pattern) {
					in_group_graph_pattern = true;
					translate_group_or_union_graph_pattern (sql);
				} else {
					if (in_triples_block) {
						end_triples_block (sql, ref first_where, in_group_graph_pattern);
						in_triples_block = false;
					}
					if (!in_group_graph_pattern) {
						in_group_graph_pattern = true;
					}

					sql.insert (group_graph_pattern_start, "SELECT * FROM (");
					sql.append (") NATURAL INNER JOIN (");
					translate_group_or_union_graph_pattern (sql);
					sql.append (")");
				}
			} else if (current () == SparqlTokenType.FILTER) {
				filters += get_location ();
				skip_filter ();
			} else {
				break;
			}

			accept (SparqlTokenType.DOT);

			// optional TriplesBlock
			parse_triples (sql, group_graph_pattern_start, ref in_triples_block, ref first_where, ref in_group_graph_pattern, found_simple_optional);
		}

		expect (SparqlTokenType.CLOSE_BRACE);

		if (!in_triples_block && !in_group_graph_pattern) {
			// empty graph pattern => return one result without bound variables
			sql.append ("SELECT 1");
		} else if (in_triples_block) {
			end_triples_block (sql, ref first_where, in_group_graph_pattern);
			in_triples_block = false;
		}

		if (in_group_graph_pattern) {
			first_where = true;
		}

		// handle filters last, they apply to the pattern as a whole
		if (filters.length > 0) {
			var end = get_location ();

			foreach (var filter_location in filters) {
				if (!first_where) {
					sql.append (" AND ");
				} else {
					sql.append (" WHERE ");
					first_where = false;
				}

				set_location (filter_location);
				translate_filter (sql);
			}

			set_location (end);
		}
	}

	void translate_group_or_union_graph_pattern (StringBuilder sql) throws Error {
		var old_subgraph_var_set = subgraph_var_set;

		Variable[] all_vars = { };
		HashTable<Variable,int> all_var_set = new HashTable<Variable,int>.full (direct_hash, direct_equal, g_object_unref, null);

		HashTable<Variable,int>[] var_sets = { };
		long[] offsets = { };

		do {
			subgraph_var_set = new HashTable<Variable,int>.full (direct_hash, direct_equal, g_object_unref, null);
			var_sets += subgraph_var_set;
			offsets += sql.len;
			translate_group_graph_pattern (sql);
		} while (accept (SparqlTokenType.UNION));

		if (var_sets.length > 1) {
			// union graph pattern

			// create union of all variables
			foreach (var var_set in var_sets) {
				foreach (var v in var_set.get_keys ()) {
					if (all_var_set.lookup (v) == 0) {
						all_vars += v;
						all_var_set.insert (v, VariableState.BOUND);
						old_subgraph_var_set.insert (v, VariableState.BOUND);
					}
				}
			}

			long extra_offset = 0;
			for (int i = 0; i < var_sets.length; i++) {
				var projection = new StringBuilder ();
				if (i > 0) {
					projection.append (") UNION ALL ");
				}
				projection.append ("SELECT ");
				foreach (var v in all_vars) {
					if (var_sets[i].lookup (v) == 0) {
						// variable not used in this subgraph
						// use NULL
						projection.append ("NULL AS ");
					}
					projection.append_printf ("%s, ", v.sql_expression);
				}
				// delete last comma and space
				projection.truncate (projection.len - 2);
				projection.append (" FROM (");

				sql.insert (offsets[i] + extra_offset, projection.str);
				extra_offset += projection.len;
			}
			sql.append (")");
		} else {
			foreach (var key in subgraph_var_set.get_keys ()) {
				old_subgraph_var_set.insert (key, VariableState.BOUND);
			}
		}
		subgraph_var_set = old_subgraph_var_set;
	}

	void parse_object (StringBuilder sql, bool in_simple_optional = false) throws SparqlError {
		bool object_is_var;
		string object = parse_var_or_term (sql, out object_is_var);

		string db_table;
		bool rdftype = false;
		bool share_table = true;
		bool is_fts_match = false;

		bool newtable;
		DataTable table;
		Property prop = null;

		if (!current_predicate_is_var) {
			prop = Ontology.get_property_by_uri (current_predicate);

			if (current_predicate == "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
			    && !object_is_var) {
				// rdf:type query
				rdftype = true;
				var cl = Ontology.get_class_by_uri (object);
				if (cl == null) {
					throw new SparqlError.UNKNOWN_CLASS ("Unknown class `%s'".printf (object));
				}
				db_table = cl.name;
			} else if (prop == null) {
				if (current_predicate == "http://www.tracker-project.org/ontologies/fts#match") {
					// fts:match
					db_table = "fts";
					share_table = false;
					is_fts_match = true;
				} else {
					throw new SparqlError.UNKNOWN_PROPERTY ("Unknown property `%s'".printf (current_predicate));
				}
			} else {
				if (current_predicate == "http://www.w3.org/2000/01/rdf-schema#domain"
				    && current_subject_is_var
				    && !object_is_var) {
					// rdfs:domain
					var domain = Ontology.get_class_by_uri (object);
					if (domain == null) {
						throw new SparqlError.UNKNOWN_CLASS ("Unknown class `%s'".printf (object));
					}
					var pv = predicate_variable_map.lookup (get_variable (current_subject));
					if (pv == null) {
						pv = new PredicateVariable ();
						predicate_variable_map.insert (get_variable (current_subject), pv);
					}
					pv.domain = domain;
				}

				if (prop.multiple_values) {
					db_table = "%s_%s".printf (prop.domain.name, prop.name);
					// we can never share the table with multiple triples
					// for multi value properties as a property may consist of multiple rows
					share_table = false;
				} else {
					db_table = prop.domain.name;
				}

				if (in_simple_optional && subgraph_var_set.lookup (get_variable (current_subject)) == 0) {
					// use subselect instead of join in simple optional where the subject is the unbound variable
					// this can only happen with inverse functional properties
					var binding = new VariableBinding ();
					binding.data_type = PropertyType.RESOURCE;
					binding.variable = get_variable (current_subject);

					assert (pattern_var_map.lookup (binding.variable) == null);
					var binding_list = new VariableBindingList ();
					pattern_variables.append (binding.variable);
					pattern_var_map.insert (binding.variable, binding_list);

					// need to use table and column name for object, can't refer to variable in nested select
					var object_binding = pattern_var_map.lookup (get_variable (object)).list.data;

					sql.append_printf ("(SELECT ID FROM \"%s\" WHERE \"%s\" = \"%s\".\"%s\") AS %s, ",
						db_table,
						prop.name,
						object_binding.table.sql_query_tablename, object_binding.sql_db_column_name,
						binding.variable.sql_expression);

					subgraph_var_set.insert (binding.variable, VariableState.OPTIONAL);
					binding_list.list.append (binding);

					assert (binding.variable.binding == null);
					binding.variable.binding = binding;

					return;
				}
			}
			table = get_table (current_subject, db_table, share_table, out newtable);
		} else {
			// variable in predicate
			newtable = true;
			table = new DataTable ();
			table.predicate_variable = predicate_variable_map.lookup (get_variable (current_predicate));
			if (table.predicate_variable == null) {
				table.predicate_variable = new PredicateVariable ();
				predicate_variable_map.insert (get_variable (current_predicate), table.predicate_variable);
			}
			if (!current_subject_is_var) {
				// single subject
				table.predicate_variable.subject = current_subject;
			}
			if (!current_subject_is_var) {
				// single object
				table.predicate_variable.object = object;
			}
			table.sql_query_tablename = current_predicate + (++counter).to_string ();
			tables.append (table);

			// add to variable list
			var binding = new VariableBinding ();
			binding.data_type = PropertyType.RESOURCE;
			binding.variable = get_variable (current_predicate);
			binding.table = table;
			binding.sql_db_column_name = "predicate";
			var binding_list = pattern_var_map.lookup (binding.variable);
			if (binding_list == null) {
				binding_list = new VariableBindingList ();
				pattern_variables.append (binding.variable);
				pattern_var_map.insert (binding.variable, binding_list);

				sql.append_printf ("\"%s\".\"%s\" AS %s, ",
					binding.table.sql_query_tablename,
					binding.sql_db_column_name,
					binding.variable.sql_expression);

				subgraph_var_set.insert (binding.variable, VariableState.BOUND);
			}
			binding_list.list.append (binding);
			if (binding.variable.binding == null) {
				binding.variable.binding = binding;
			}
		}
		
		if (newtable) {
			if (current_subject_is_var) {
				var binding = new VariableBinding ();
				binding.data_type = PropertyType.RESOURCE;
				binding.variable = get_variable (current_subject);
				binding.table = table;
				if (is_fts_match) {
					binding.sql_db_column_name = "rowid";
				} else {
					binding.sql_db_column_name = "ID";
				}
				var binding_list = pattern_var_map.lookup (binding.variable);
				if (binding_list == null) {
					binding_list = new VariableBindingList ();
					pattern_variables.append (binding.variable);
					pattern_var_map.insert (binding.variable, binding_list);

					sql.append_printf ("\"%s\".\"%s\" AS %s, ",
						binding.table.sql_query_tablename,
						binding.sql_db_column_name,
						binding.variable.sql_expression);

					subgraph_var_set.insert (binding.variable, VariableState.BOUND);
				}
				binding_list.list.append (binding);
				if (binding.variable.binding == null) {
					binding.variable.binding = binding;
				}
			} else {
				var binding = new LiteralBinding ();
				binding.data_type = PropertyType.RESOURCE;
				binding.literal = current_subject;
				// binding.data_type = triple.subject.type;
				binding.table = table;
				binding.sql_db_column_name = "ID";
				pattern_bindings.append (binding);
			}
		}
		
		if (!rdftype) {
			if (object_is_var) {
				var binding = new VariableBinding ();
				binding.variable = get_variable (object);
				binding.table = table;
				if (prop != null) {

					binding.type = prop.range.uri;

					binding.data_type = prop.data_type;
					binding.sql_db_column_name = prop.name;
					if (!prop.multiple_values) {
						// for single value properties, row may have NULL
						// in any column except the ID column
						binding.maybe_null = true;
						binding.in_simple_optional = in_simple_optional;
					}
				} else {
					// variable as predicate
					binding.sql_db_column_name = "object";
					binding.maybe_null = true;
				}

				var binding_list = pattern_var_map.lookup (binding.variable);
				if (binding_list == null) {
					binding_list = new VariableBindingList ();
					pattern_variables.append (binding.variable);
					pattern_var_map.insert (binding.variable, binding_list);

					sql.append_printf ("\"%s\".\"%s\" AS %s, ",
						binding.table.sql_query_tablename,
						binding.sql_db_column_name,
						binding.variable.sql_expression);

					VariableState state;
					if (in_simple_optional) {
						state = VariableState.OPTIONAL;
					} else {
						state = VariableState.BOUND;
					}
					subgraph_var_set.insert (binding.variable, state);
				}
				binding_list.list.append (binding);
				if (binding.variable.binding == null) {
					binding.variable.binding = binding;
				}
			} else if (is_fts_match) {
				var binding = new LiteralBinding ();
				binding.is_fts_match = true;
				binding.literal = object;
				// binding.data_type = triple.object.type;
				binding.table = table;
				binding.sql_db_column_name = "fts";
				pattern_bindings.append (binding);

				sql.append_printf ("rank(\"%s\".\"fts\") AS \"%s_u_rank\", ",
					binding.table.sql_query_tablename,
					get_variable (current_subject).name);
				sql.append_printf ("offsets(\"%s\".\"fts\") AS \"%s_u_offsets\", ",
					binding.table.sql_query_tablename,
					get_variable (current_subject).name);
			} else {
				var binding = new LiteralBinding ();
				binding.literal = object;
				// binding.data_type = triple.object.type;
				binding.table = table;
				if (prop != null) {
					binding.data_type = prop.data_type;
					binding.sql_db_column_name = prop.name;
				} else {
					// variable as predicate
					binding.sql_db_column_name = "object";
				}
				pattern_bindings.append (binding);
			}
		}

		if (!current_subject_is_var &&
		    !current_predicate_is_var &&
		    !object_is_var) {
			// no variables involved, add dummy expression to SQL
			sql.append ("1, ");
		}
	}

	DataTable get_table (string subject, string db_table, bool share_table, out bool newtable) {
		string tablestring = "%s.%s".printf (subject, db_table);
		DataTable table = null;
		newtable = false;
		if (share_table) {
			table = table_map.lookup (tablestring);
		}
		if (table == null) {
			newtable = true;
			table = new DataTable ();
			table.sql_db_tablename = db_table;
			table.sql_query_tablename = db_table + (++counter).to_string ();
			tables.append (table);
			table_map.insert (tablestring, table);
		}
		return table;
	}

	static string? get_string_for_value (Value value)
	{
		if (value.type () == typeof (int)) {
			return value.get_int ().to_string ();
		} else if (value.type () == typeof (double)) {
			return value.get_double ().to_string ();
		} else if (value.type () == typeof (string)) {
			return value.get_string ();
		} else {
			return null;
		}
	}

	[CCode (cname = "uuid_generate")]
	public extern static void uuid_generate ([CCode (array_length = false)] uchar[] uuid);
}

