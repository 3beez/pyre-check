# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import logging
from typing import Tuple

from .db import DB
from .models import create as create_models
from .pipeline import DictEntries, PipelineStep, Summary
from .trace_graph import TraceGraph


log = logging.getLogger("sapp")


class CreateDatabase(PipelineStep[DictEntries, TraceGraph]):
    def __init__(self, database: DB) -> None:
        super().__init__()
        self.database = database

    def run(  # pyre-fixme[14]
        self, input: TraceGraph, summary: Summary
    ) -> Tuple[TraceGraph, Summary]:
        create_models(self.database)
        return input, summary
