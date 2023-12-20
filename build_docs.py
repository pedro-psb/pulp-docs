
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path
from textwrap import indent
from urllib.request import urlretrieve

import yaml
from jinja2 import Environment, FileSystemLoader

BASE_URL = "file:///home/pbrochad/workspace/multirepo-prototype"
REPOSITORIES = {
    "new_repo1": {
        "title": "RPM Package",
        "url": f"{BASE_URL}/new_repo1",
        "code_basepaths": ["new_repo1"],
    },
    "new_repo2": {
        "title": "Debian Package",
        "url": f"{BASE_URL}/new_repo2",
        "code_basepaths": ["new_repo2"],
    },
    "new_repo3": {
        "title": "Maven",
        "url": f"{BASE_URL}/new_repo3",
        "code_basepaths": ["new_repo3"],
    },
}


def get_doctrees():
    doctrees = {}
    for reponame, repodata in REPOSITORIES.items():
        url = repodata["url"]
        with tempfile.TemporaryDirectory() as tmpdir:
            path, _ = urlretrieve(f"{url}/docs/doctree.json",
                                  f"{tmpdir}/{reponame}_doctree.json")
            with open(path, "r") as file:
                doctrees[reponame] = json.load(file)
    return doctrees


# Data about all documenation files from each repo organized by {persona}_{content-type}
# See how a 'doctree.json' looks like
doc_trees = get_doctrees()


def import_from(repo: str, docs_dir: str = "docs/*", branch="main", config="docs/mkdocs.yml"):
    url = "file:///home/pbrochad/workspace/multirepo-prototype"
    return f'!import {url}/{repo}?branch={branch}&docs_dir={docs_dir}&config={config}'


def sanitize_path(path: str):
    """Replace _ for - in the reponame because its tweaked by the plugin"""
    parts = Path(path).parts
    newparts = (parts[0].replace("_", "-"),) + parts[1:]
    return str(Path("/".join(newparts)))


def RepoContent(persona: str, content_type: str):
    """
    Collect content from repositories for @persona and @content_type.

    Return:
        one-level:  [{title: import-url}, ...]
        two-levels: [{title: [{title: import-url}, ...]}]
    """

    content_list = []
    for reponame, repodata in REPOSITORIES.items():
        contents = doc_trees[reponame][f"{persona}_{content_type}"]
        repochild = [sanitize_path(content["path"]) for content in contents]
        content_list.append({repodata['title']: repochild})
    return content_list


def RepoReference():
    """Collect reference data from repositories."""
    content_list = []
    for reponame, repodata in REPOSITORIES.items():
        contents = doc_trees[reponame]["reference"]
        code_api = []
        for content in contents:
            if content["type"] == "file":
                code_api.append(sanitize_path(content["path"]))
            else:

                subtitle = content["name"].title()
                _basepath = sanitize_path(content["path"])
                children = [
                    f"{_basepath}/{child}" for child in content["children"]]
                code_api.append({subtitle: children})
        name = reponame.replace("_", "-")  # workaround
        repochild = [
            {"Code API": code_api},
            {"Changelog": f"{name}/CHANGELOG.md"},
        ]
        content_list.append({repodata['title']: repochild})
    return content_list


def CoreContent(content_path: str):
    glob_result = Path(f"docs/{content_path}").glob("*")
    files = []
    for path in glob_result:
        if path.is_file() and not path.name.startswith("_"):
            files.append(str(path.relative_to("docs")))
        elif path.is_dir() and not path.name.startswith("_"):
            title = path.name.title()
            sub_glob_result = path.glob("*.md")
            files.append({title: [str(child.relative_to(
                # type: ignore
                "docs")) for child in sub_glob_result if not child.name.startswith("_")]})

    return files


def get_multirepo_imports():
    """Import definitions for all Pulp Project repositories."""
    multirepos_import = []
    for reponame, repodata in REPOSITORIES.items():
        multirepos_import.append({
            "name": reponame,
            "import_url": repodata["url"] + "?branch=main",
            "imports": ["docs/*", *repodata["code_basepaths"], "CHANGELOG.md"],
        })
    return multirepos_import


def get_mkdocstrings_paths():
    """
    Paths discoverable by mkdocstrings plugin for generating reference doc.

    For more info, see: https://github.com/jdoiro3/mkdocs-multirepo-plugin/issues/110
    """
    return ["temp_dir/{}".format(name.replace("_", "-")) for name, _ in REPOSITORIES.items()]


def get_navigation():
    """The dynamic generated 'nav' section of mkdocs.yml"""
    getting_started = [
        {"Overview": "getting_started/index.md"},
        {"Quickstart": CoreContent("getting_started/quickstart/")},
        {"Fundamentals": CoreContent("getting_started/fundamentals/")}
    ]
    guides = [
        {"Overview": "guides/index.md"},
        {"For Content-Management": RepoContent("content-manager", "guides")},
        {"For Sys-Admins": RepoContent("sys-admin", "guides")},
    ]
    learn = [
        {"Overview": "learn/index.md"},
        {"For Content-Management": RepoContent("content-manager", "learn")},
        {"For Sys-Admins": RepoContent("sys-admin", "learn")},
    ]
    reference = [
        {"Overview": "reference/index.md"},
        {"Repository Map": "reference/01-repository-map.md"},
        {"Glossary": "reference/02-glossary.md"},
        {"Repositories": RepoReference()},
    ]
    development = [
        {"Overview": "development/index.md"},
        {"Quickstart": CoreContent("development/quickstart/")},
        {"Onboarding": CoreContent("development/onboarding/")},
        {"Guides": CoreContent("development/guides/")},
    ]

    # main navigation
    navigation = [
        {"Home": "index.md"},
        {"Getting Started": getting_started},
        {"Guides": guides},
        {"Learn": learn},
        {"Reference": reference},
        {"Development": development},
    ]
    return navigation


def main():
    # dynamic generated mkdocs.yml sections
    navigation = get_navigation()
    multirepo_imports = get_multirepo_imports()
    mkdocstrings_paths = get_mkdocstrings_paths()

    # creating mkdocs.yml with dynamic sections
    jinja = Environment(loader=FileSystemLoader(Path()))
    template = jinja.get_template("mkdocs.yml.j2")
    result = template.render(
        navigation=indent(yaml.dump(navigation), prefix="  "),
        mkdocstrings_paths=indent(
            yaml.dump(mkdocstrings_paths), prefix="  "*6),
        multirepo_imports=indent(yaml.dump(multirepo_imports), prefix="  "*4)
    )

    file = Path() / "mkdocs.yml"
    file.write_text(result)


if __name__ == "__main__":
    sys.exit(main())