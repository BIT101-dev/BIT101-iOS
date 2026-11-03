"""Locate Python code in shell arguments and here-documents."""

import re
import shlex
from pathlib import Path


def read_heredoc(source, start, header, path):
    body = []
    position = start
    for line in source[start:].splitlines(keepends=True):
        end = position
        position += len(line)
        line = line.lstrip("\t") if header["tabs"] else line
        if line.rstrip("\r\n") == header["label"]:
            return "".join(body), end, position
        body.append(line)
    raise SyntaxError(f"{path}: heredoc 结束标记缺失")


def command_words(prefix, *, first=False):
    lexer = shlex.shlex(prefix, posix=True, punctuation_chars=";|&()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        words = list(lexer)
    except ValueError:
        return []
    boundaries = [index for index, word in enumerate(words) if set(word) <= set(";|&()")]
    if first:
        return words[: boundaries[0]] if boundaries else words
    return words[boundaries[-1] + 1 :] if boundaries else words


def consume_env_options(words):
    while words and words[0].startswith("-"):
        option = words.pop(0)
        if option in {"-u", "--unset", "-C", "--chdir"}:
            if not words:
                return False
            words.pop(0)
        elif option == "--":
            break
        elif option not in {"-i", "--ignore-environment"} and not option.startswith(
            ("--unset=", "--chdir=")
        ):
            return False
    return True


def python_command_words(prefix, suffix=""):
    words = command_words(prefix) + command_words(suffix, first=True)
    while words:
        if re.match(r"^[A-Za-z_]\w*=", words[0]) or words[0] in {
            "command",
            "exec",
            "if",
            "elif",
            "then",
            "do",
            "while",
            "until",
            "{",
            "!",
        }:
            words.pop(0)
        elif words[0] == "time":
            words.pop(0)
            if words and words[0] == "-p":
                words.pop(0)
        elif Path(words[0]).name == "env":
            words.pop(0)
            if not consume_env_options(words):
                return None
        else:
            break
    if not words or not re.fullmatch(r"python(?:\d+(?:\.\d+)*)?", Path(words.pop(0)).name):
        return None
    return words


def inline_python_command(prefix):
    words = python_command_words(prefix)
    if words is None:
        return False
    while words:
        option = words.pop(0)
        if option == "-c" or re.fullmatch(r"-[bBdEiIOPqRsSuvVx]*c", option):
            return not words
        if option in {"-W", "-X"}:
            if not words:
                return False
            words.pop(0)
        elif not option.startswith("-") or option in {"-", "--", "-m"}:
            return False
    return False


def python_reads_descriptor(prefix, suffix="", descriptor="0"):
    words = python_command_words(prefix, suffix)
    if words is None:
        return False
    while words:
        option = words.pop(0)
        if option == "--":
            option = words.pop(0) if words else "-"
        if option == "-":
            return descriptor == "0"
        if re.match(r"-[bBdEiIOPqRsSuvVx]*[cm]", option):
            return False
        if option in {"-W", "-X"}:
            if not words:
                return False
            words.pop(0)
        elif not option.startswith("-"):
            return (
                option in {f"/dev/fd/{descriptor}", f"/proc/self/fd/{descriptor}"}
                or descriptor == "0"
                and option == "/dev/stdin"
            )
    return descriptor == "0"


def ansi_literal(body):
    escapes = {
        "a": b"\a",
        "b": b"\b",
        "e": b"\x1b",
        "E": b"\x1b",
        "f": b"\f",
        "n": b"\n",
        "r": b"\r",
        "t": b"\t",
        "v": b"\v",
        "\\": b"\\",
        "'": b"'",
        '"': b'"',
        "?": b"?",
    }
    pattern = re.compile(
        (
            "\\\\(?:([abEefnrtv\\\\'\"?])|x([\\da-fA-F]{1,2})|u([\\da-fA-F]{1,4})|U([\\d"
            "a-fA-F]{1,8})|([0-7]{1,3})|(.))"
        ),
        re.DOTALL,
    )
    result, position = bytearray(), 0
    for match in pattern.finditer(body):
        result.extend(body[position : match.start()].encode())
        escape, hexadecimal, short_unicode, long_unicode, octal, other = match.groups()
        if escape:
            result.extend(escapes[escape])
        elif hexadecimal:
            result.append(int(hexadecimal, 16))
        elif short_unicode or long_unicode:
            result.extend(chr(int(short_unicode or long_unicode, 16)).encode())
        elif octal:
            result.append(int(octal, 8) & 255)
        else:
            result.extend(other.encode())
        position = match.end()
    result.extend(body[position:].encode())
    return bytes(result).split(b"\0", 1)[0]


def quoted_command(source, position, *, ansi=False):
    quote, body, literal = source[position], [], True
    position += 1
    while position < len(source):
        character = source[position]
        if character == quote:
            value = "".join(body)
            return ansi_literal(value) if ansi else value.encode(), position + 1, literal
        if ansi and character == "\\" and position + 1 < len(source):
            body.extend(source[position : position + 2])
            position += 2
            continue
        if quote == '"' and character == "\\" and position + 1 < len(source):
            following = source[position + 1]
            if following in '$`"\\\n':
                if following != "\n":
                    body.append(following)
                position += 2
                continue
        if quote == '"' and character in "$`":
            literal = False
        body.append(character)
        position += 1
    raise SyntaxError("Python -c 引号需要完整闭合")


def command_argument(source, position):
    body, literal = bytearray(), True
    while position < len(source) and source[position] not in " \t\r\n;|&()<>`":
        ansi = source.startswith("$'", position)
        if ansi or source[position] in "'\"":
            value, position, segment_literal = quoted_command(
                source, position + int(ansi), ansi=ansi
            )
            body.extend(value)
            literal &= segment_literal
        elif source[position] == "\\" and position + 1 < len(source):
            if source[position + 1] != "\n":
                body.extend(source[position + 1].encode())
            position += 2
        else:
            if source[position] in "$`*?[":
                literal = False
            body.extend(source[position].encode())
            position += 1
    return bytes(body), position, literal


def visit_python_shell(source, path, visit):
    headers = re.compile(r"(?<!<)(?:(?<![^\s;|&()])(?P<descriptor>\d+))?<<(?!<)(?P<tabs>-)?[ \t]*")
    redirects = re.compile(r"(?:\d+)?(?:&>>?|[<>]&|<>|>>?|<)(?!<)[ \t]*")
    visible = [" "] * len(source)
    contexts = [("command", 0)]
    pending = []
    position = line_start = 0
    while position < len(source):
        character = source[position]
        context, context_start = contexts[-1]
        if context in {"command", "backtick"} and (redirect := redirects.match(source, position)):
            _, end, _ = command_argument(source, redirect.end())
            position = end
            continue
        if (
            context in {"command", "backtick"}
            and character not in " \t\r\n;|&()<>#`"
            and not source.startswith("\\\n", position)
            and inline_python_command("".join(visible[max(line_start, context_start) : position]))
        ):
            argument_start = position
            body, position, literal = command_argument(source, position)
            if literal:
                visit(body.decode("utf-8"), argument_start, position, True)
            visible[argument_start] = "#"
            line_start = source.rfind("\n", 0, position) + 1
            continue
        if character == "\\" and context != "'":
            position += 2
            continue
        if context in {"'", '"'}:
            if character == context:
                contexts.pop()
            elif context == '"' and source.startswith("$(", position):
                contexts.append(("command", position + 2))
                position += 1
            elif context == '"' and character == "`":
                contexts.append(("backtick", position + 1))
            position += 1
            continue
        if character == "#" and (position == 0 or source[position - 1] in " \t\n;|&()"):
            newline = source.find("\n", position)
            position = len(source) if newline < 0 else newline
            continue
        if character in "'\"":
            ansi = character == "'" and position > 0 and visible[position - 1] == "$"
            argument_start = position - int(ansi)
            body, end, literal = quoted_command(source, position, ansi=ansi)
            if literal:
                visible[argument_start] = shlex.quote(
                    body.decode("utf-8", errors="surrogateescape")
                )
                position = end
                continue
            visible[position] = "_"
            contexts.append((character, position))
            position += 1
            continue
        if character == "(":
            contexts.append(("command", position + 1))
        elif character == ")" and len(contexts) > 1:
            contexts.pop()
        elif character == "`":
            if context == "backtick":
                contexts.pop()
            else:
                contexts.append(("backtick", position + 1))
            position += 1
            continue
        if character == "\n" and pending:
            position += 1
            command_end = position - 1
            for header in pending:
                suffix = "".join(visible[header["end"] : command_end])
                is_python = header["label"].startswith("PY") or python_reads_descriptor(
                    header["opening"], suffix, header["descriptor"]
                )
                start = position
                body, end, position = read_heredoc(source, start, header, path)
                if is_python:
                    visit(body, start, end, False)
            pending.clear()
            line_start = position
            continue
        header = headers.match(source, position)
        if header is None:
            visible[position] = character
            if character == "\n":
                line_start = position + 1
            position += 1
            continue
        opening = "".join(visible[max(line_start, context_start) : position])
        label, end, _ = command_argument(source, header.end())
        if not label:
            raise SyntaxError(f"{path}: heredoc 需要结束标记")
        delimiter = label.decode("utf-8")
        pending.append(
            {
                "tabs": header["tabs"],
                "label": delimiter,
                "opening": opening,
                "end": end,
                "descriptor": header["descriptor"] or "0",
            }
        )
        position = end
    if pending:
        raise SyntaxError(f"{path}: heredoc 正文缺失")
