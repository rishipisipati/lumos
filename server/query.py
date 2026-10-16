import datetime
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class SearchQuery:
    name_or_groups: list
    name_globs: list
    extensions: list
    path_substring: str
    files_only: bool
    folders_only: bool
    min_size: int
    max_size: int
    modified_after: float
    modified_before: float
    has_path: bool
    has_min_size: bool
    has_max_size: bool
    has_modified_after: bool
    has_modified_before: bool

    @property
    def is_empty(self):
        return (
            not self.name_or_groups
            and not self.name_globs
            and not self.extensions
            and not self.has_path
            and not self.files_only
            and not self.folders_only
            and not self.has_min_size
            and not self.has_max_size
            and not self.has_modified_after
            and not self.has_modified_before
        )


def parse_query(raw):
    tokens = tokenize_query(raw)
    name_or_groups = []
    name_globs = []
    extensions = []
    path_substring = ""
    has_path = False
    files_only = False
    folders_only = False
    min_size = 0
    max_size = 0
    has_min_size = False
    has_max_size = False
    modified_after = 0.0
    modified_before = 0.0
    has_modified_after = False
    has_modified_before = False

    for token in tokens:
        kind, value = parse_filter_token(token)
        if kind == "name":
            if "*" in value or "?" in value:
                name_globs.append(value)
            else:
                parts = [part for part in value.split("|") if part]
                if parts:
                    name_or_groups.append(parts)
        elif kind == "extensions":
            parts = [normalize_extension(part) for part in value.split(";")]
            extensions.extend([part for part in parts if part])
        elif kind == "path":
            path_substring = value
            has_path = True
        elif kind == "files_only":
            files_only = True
        elif kind == "folders_only":
            folders_only = True
        elif kind == "size":
            parsed_min, parsed_max, saw_min, saw_max = parse_size_bounds(value)
            if saw_min:
                min_size = parsed_min if not has_min_size else max(min_size, parsed_min)
                has_min_size = True
            if saw_max:
                max_size = parsed_max if not has_max_size else min(max_size, parsed_max)
                has_max_size = True
        elif kind == "modified":
            after, before, saw_after, saw_before = parse_date_bounds(value, datetime.datetime.now())
            if saw_after:
                modified_after = after if not has_modified_after else max(modified_after, after)
                has_modified_after = True
            if saw_before:
                modified_before = before if not has_modified_before else min(modified_before, before)
                has_modified_before = True

    return SearchQuery(
        name_or_groups=name_or_groups,
        name_globs=name_globs,
        extensions=extensions,
        path_substring=path_substring,
        files_only=files_only,
        folders_only=folders_only,
        min_size=min_size,
        max_size=max_size,
        modified_after=modified_after,
        modified_before=modified_before,
        has_path=has_path,
        has_min_size=has_min_size,
        has_max_size=has_max_size,
        has_modified_after=has_modified_after,
        has_modified_before=has_modified_before,
    )


def tokenize_query(raw):
    tokens = []
    current = []
    in_quotes = False
    for character in raw:
        if character == '"':
            in_quotes = not in_quotes
            continue
        if character.isspace() and not in_quotes:
            if current:
                tokens.append("".join(current))
                current = []
            continue
        current.append(character)
    if current:
        tokens.append("".join(current))
    return tokens


def parse_filter_token(token):
    if ":" not in token:
        return "name", token
    key, value = token.split(":", 1)
    key = key.lower()
    if key == "ext":
        return "extensions", value
    if key == "path":
        return "path", value
    if key == "size":
        return "size", value
    if key in ("dm", "datemodified", "date-modified"):
        return "modified", value
    if key == "file":
        return "files_only", ""
    if key == "folder":
        return "folders_only", ""
    if key == "type":
        normalized = value.lower()
        if normalized in ("folder", "dir", "directory"):
            return "folders_only", ""
        if normalized == "file":
            return "files_only", ""
    return "name", token


def normalize_extension(raw):
    value = raw.strip().lower()
    if value.startswith("."):
        value = value[1:]
    return value


def parse_size_bounds(raw):
    trimmed = raw.strip().lower()
    if not trimmed:
        return 0, 0, False, False
    comparison = ""
    rest = trimmed
    if trimmed.startswith(">=") or trimmed.startswith("<="):
        comparison = trimmed[:2]
        rest = trimmed[2:]
    elif trimmed.startswith(">") or trimmed.startswith("<"):
        comparison = trimmed[:1]
        rest = trimmed[1:]
    bytes_value = parse_byte_count(rest)
    if bytes_value is None:
        return 0, 0, False, False
    if comparison == ">":
        return bytes_value + 1, 0, True, False
    if comparison == ">=":
        return bytes_value, 0, True, False
    if comparison == "<":
        return 0, bytes_value - 1, False, True
    if comparison == "<=":
        return 0, bytes_value, False, True
    return bytes_value, bytes_value * 2 - 1, True, True


def parse_byte_count(raw):
    match = re.match(r"^([0-9]+(?:\.[0-9]+)?)(b|kb|mb|gb|tb)?$", raw)
    if match is None:
        return None
    number = float(match.group(1))
    unit = match.group(2)
    multiplier = 1
    if unit == "kb":
        multiplier = 1024
    elif unit == "mb":
        multiplier = 1024 * 1024
    elif unit == "gb":
        multiplier = 1024 * 1024 * 1024
    elif unit == "tb":
        multiplier = 1024 * 1024 * 1024 * 1024
    return int(round(number * multiplier))


def parse_date_bounds(raw, now):
    trimmed = raw.strip().lower()
    start_of_today = datetime.datetime(now.year, now.month, now.day)
    if trimmed == "today":
        return start_of_today.timestamp(), 0.0, True, False
    if trimmed == "yesterday":
        yesterday = start_of_today - datetime.timedelta(days=1)
        return yesterday.timestamp(), start_of_today.timestamp(), True, True
    if trimmed in ("thisweek", "this-week"):
        start = start_of_today - datetime.timedelta(days=start_of_today.weekday())
        return start.timestamp(), 0.0, True, False
    if trimmed in ("thismonth", "this-month"):
        start = datetime.datetime(now.year, now.month, 1)
        return start.timestamp(), 0.0, True, False
    if trimmed in ("thisyear", "this-year"):
        start = datetime.datetime(now.year, 1, 1)
        return start.timestamp(), 0.0, True, False
    parts = trimmed.split("-")
    if len(parts) == 3:
        try:
            year = int(parts[0])
            month = int(parts[1])
            day = int(parts[2])
            start = datetime.datetime(year, month, day)
            next_day = start + datetime.timedelta(days=1)
            return start.timestamp(), next_day.timestamp(), True, True
        except ValueError:
            return 0.0, 0.0, False, False
    return 0.0, 0.0, False, False


def fts_phrase(term):
    return '"' + term.replace('"', '""') + '"'


def escape_like_pattern(term):
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def build_search_sql(query, limit, offset, show_hidden):
    clauses = []
    params = []
    joins = ""
    fts_parts = []
    if query.name_or_groups:
        for group in query.name_or_groups:
            terms = [term.strip() for term in group if term.strip()]
            if not terms:
                continue
            use_fts = all(len(term) >= 3 for term in terms)
            if use_fts:
                fts_parts.append("(" + " OR ".join("name : " + fts_phrase(term) for term in terms) + ")")
            else:
                likes = []
                for term in terms:
                    likes.append("files.name LIKE ? ESCAPE '\\' COLLATE NOCASE")
                    params.append("%" + escape_like_pattern(term) + "%")
                clauses.append("(" + " OR ".join(likes) + ")")
        if fts_parts:
            joins = "JOIN files_fts ON files_fts.rowid = files.id"
            clauses.append("files_fts MATCH ?")
            params.append(" AND ".join(fts_parts))
    if query.has_path:
        clauses.append("files.path LIKE ? ESCAPE '\\' COLLATE NOCASE")
        params.append("%" + escape_like_pattern(query.path_substring) + "%")
    if query.extensions:
        placeholders = ", ".join(["?"] * len(query.extensions))
        clauses.append("files.ext IN (" + placeholders + ")")
        params.extend(query.extensions)
    if query.files_only:
        clauses.append("files.is_dir = 0")
    if query.folders_only:
        clauses.append("files.is_dir = 1")
    if query.has_min_size:
        clauses.append("files.size >= ?")
        params.append(query.min_size)
    if query.has_max_size:
        clauses.append("files.size <= ?")
        params.append(query.max_size)
    if query.has_modified_after:
        clauses.append("files.modified >= ?")
        params.append(query.modified_after)
    if query.has_modified_before:
        clauses.append("files.modified < ?")
        params.append(query.modified_before)
    if query.name_globs:
        for glob in query.name_globs:
            clauses.append("LOWER(files.name) GLOB ?")
            params.append(glob.lower())
    if not show_hidden:
        clauses.append("files.is_hidden = 0")
    where = ""
    if clauses:
        where = "WHERE " + " AND ".join(clauses)
    sql = (
        "SELECT files.name, files.path, files.parent, files.size, files.modified, "
        "files.is_dir, files.ext, files.is_hidden "
        "FROM files "
        + joins
        + (" " if joins else "")
        + where
        + " LIMIT ? OFFSET ?"
    )
    params.append(limit)
    params.append(offset)
    return sql, params
