#!/bin/bash

# This script generates a self-contained HTML file with interactive charts
# from a SQLite benchmark summary report.

# --- Check for input file ---
if [ -z "$1" ]; then
  echo "Error: Please provide the path to the summary report file."
  echo "Usage: $0 /path/to/summary_report.txt"
  exit 1
fi

if [ ! -f "$1" ]; then
  echo "Error: File not found at '$1'"
  exit 1
fi

# --- Read the results data from the provided file ---
RESULTS_DATA=$(awk '1' "$1")
OUTPUT_FILE="results_chart.html"

# --- Generate the HTML file using a Heredoc ---
cat > "$OUTPUT_FILE" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SQLite Performance Benchmark Results</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/react@17/umd/react.production.min.js"></script>
    <script src="https://unpkg.com/react-dom@17/umd/react-dom.production.min.js"></script>
    <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
    <script src="https://unpkg.com/recharts@2.1.9/umd/Recharts.min.js"></script>
    <style>
        body { font-family: 'Inter', sans-serif; }
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;700;800&display=swap');
    </style>
</head>
<body class="bg-gray-900">
    <div id="root"></div>

    <script type="text/babel" data-presets="react">
        const { useState, useMemo, useEffect } = React;
        const { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer, Cell } = Recharts;

        const rawData = \`$RESULTS_DATA\`;

        const parseData = (text) => {
          const lines = text.trim().split('\\n');
          const data = [];
          for (let i = 4; i < lines.length; i++) {
            const line = lines[i];
            if (!line.includes('|')) continue;
            const parts = line.split('|').map(p => p.trim());
            if (parts.length < 5 || !parts[3]) continue;
            data.push({
              storage: parts[0],
              size: parts[1],
              pragma: parts[2],
              benchmark: parts[3],
              ops: parseFloat(parts[4]),
              name: \`\${parts[0]} | \${parts[1]} | \${parts[2]}\`,
            });
          }
          return data;
        };

        const COLORS = { memory: '#3b82f6', tmpfs: '#22c55e', nvme: '#f97316', pmem: '#a855f7' };
        const BENCHMARK_TITLES = {
          fillseq: 'Sequential Writes (fillseq)',
          fillrandom: 'Random Writes (fillrandom)',
          readseq: 'Sequential Reads (readseq)',
          readrandom: 'Random Reads (readrandom)',
          readwrite: 'Mixed Read/Write (readwrite)',
        };

        const CustomTooltip = ({ active, payload, label }) => {
          if (active && payload && payload.length) {
            return (
              <div className="p-4 bg-gray-800 bg-opacity-90 border border-gray-700 rounded-lg shadow-lg text-white">
                <p className="font-bold text-lg mb-2">{label}</p>
                <p className="text-base text-cyan-400">{\`Operations/sec: \${payload[0].value.toLocaleString(undefined, {maximumFractionDigits: 0})}\`}</p>
              </div>
            );
          }
          return null;
        };
        
        // A reusable checkbox component for the filter UI
        const FilterCheckbox = ({ label, checked, onChange }) => (
            <label className="flex items-center space-x-2 cursor-pointer text-gray-300 hover:text-white">
                <input type="checkbox" checked={checked} onChange={onChange} className="form-checkbox h-4 w-4 rounded bg-gray-700 border-gray-600 text-cyan-600 focus:ring-cyan-500" />
                <span>{label}</span>
            </label>
        );

        function App() {
          const allData = useMemo(() => parseData(rawData), []);
          
          const { benchmarks, storageTypes, sizes, pragmaSetups } = useMemo(() => {
            const allBenchmarks = [...new Set(allData.map(item => item.benchmark).filter(Boolean))];
            const allStorage = [...new Set(allData.map(item => item.storage).filter(Boolean))];
            const allSizes = [...new Set(allData.map(item => item.size).filter(Boolean))];
            const allPragmas = [...new Set(allData.map(item => item.pragma).filter(Boolean))];
            return { benchmarks: allBenchmarks, storageTypes: allStorage, sizes: allSizes, pragmaSetups: allPragmas };
          }, [allData]);

          const [selectedBenchmark, setSelectedBenchmark] = useState(benchmarks.length > 0 ? benchmarks[0] : '');
          const [selectedStorage, setSelectedStorage] = useState(storageTypes);
          const [selectedSizes, setSelectedSizes] = useState(sizes);
          const [selectedPragmas, setSelectedPragmas] = useState(pragmaSetups);

          const handleFilterChange = (setter, selectedItems, item) => {
            const newSelected = selectedItems.includes(item)
              ? selectedItems.filter(i => i !== item)
              : [...selectedItems, item];
            setter(newSelected);
          };

          const handleSelectAll = (setter, allItems, selectedItems) => {
            if (selectedItems.length === allItems.length) {
              setter([]);
            } else {
              setter(allItems);
            }
          };

          const chartData = useMemo(() => 
            allData
              .filter(d => 
                d.benchmark === selectedBenchmark &&
                selectedStorage.includes(d.storage) &&
                selectedSizes.includes(d.size) &&
                selectedPragmas.includes(d.pragma)
              )
              .sort((a, b) => b.ops - a.ops),
            [allData, selectedBenchmark, selectedStorage, selectedSizes, selectedPragmas]
          );

          const yAxisFormatter = (value) => {
            if (value >= 1000000) return \`\${(value / 1000000).toFixed(1)}M\`;
            if (value >= 1000) return \`\${(value / 1000).toFixed(0)}K\`;
            return value;
          };

          return (
            <div className="bg-gray-900 text-gray-200 min-h-screen font-sans p-4 sm:p-6 lg:p-8">
              <div className="max-w-7xl mx-auto">
                <header className="text-center mb-8">
                  <h1 className="text-4xl font-extrabold text-white tracking-tight">SQLite Performance Analysis</h1>
                  <p className="mt-2 text-lg text-gray-400">Comparing different storage backends and configurations.</p>
                </header>

                <nav className="mb-8 p-4 bg-gray-800 rounded-xl shadow-md">
                  <h2 className="text-lg font-semibold text-white mb-3 text-center">Select a Benchmark to View</h2>
                  <div className="flex flex-wrap justify-center gap-2">
                    {benchmarks.map(b => (
                      <button key={b} onClick={() => setSelectedBenchmark(b)}
                        className={\`px-4 py-2 text-sm font-medium rounded-md transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-gray-800 focus:ring-cyan-500 \${
                          selectedBenchmark === b ? 'bg-cyan-600 text-white shadow-lg' : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                        }\`}>
                        {BENCHMARK_TITLES[b] || b}
                      </button>
                    ))}
                  </div>
                </nav>

                <div className="grid grid-cols-1 lg:grid-cols-4 gap-6 mb-8">
                    <div className="lg:col-span-4 bg-gray-800 rounded-xl shadow-md p-4">
                        <h3 className="text-lg font-semibold text-white mb-4 text-center">Filter Results</h3>
                        <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-6">
                            {/* Storage Filter */}
                            <div className="space-y-2">
                                <h4 className="font-bold border-b border-gray-700 pb-1">Storage Type</h4>
                                <FilterCheckbox label="Select All" checked={selectedStorage.length === storageTypes.length} onChange={() => handleSelectAll(setSelectedStorage, storageTypes, selectedStorage)} />
                                {storageTypes.map(s => <FilterCheckbox key={s} label={s} checked={selectedStorage.includes(s)} onChange={() => handleFilterChange(setSelectedStorage, selectedStorage, s)} />)}
                            </div>
                            {/* Size Filter */}
                            <div className="space-y-2">
                                <h4 className="font-bold border-b border-gray-700 pb-1">Database Size</h4>
                                <FilterCheckbox label="Select All" checked={selectedSizes.length === sizes.length} onChange={() => handleSelectAll(setSelectedSizes, sizes, selectedSizes)} />
                                {sizes.map(s => <FilterCheckbox key={s} label={s} checked={selectedSizes.includes(s)} onChange={() => handleFilterChange(setSelectedSizes, selectedSizes, s)} />)}
                            </div>
                            {/* PRAGMA Filter */}
                            <div className="space-y-2">
                                <h4 className="font-bold border-b border-gray-700 pb-1">PRAGMA Setup</h4>
                                <FilterCheckbox label="Select All" checked={selectedPragmas.length === pragmaSetups.length} onChange={() => handleSelectAll(setSelectedPragmas, pragmaSetups, selectedPragmas)} />
                                {pragmaSetups.map(p => <FilterCheckbox key={p} label={p} checked={selectedPragmas.includes(p)} onChange={() => handleFilterChange(setSelectedPragmas, selectedPragmas, p)} />)}
                            </div>
                        </div>
                    </div>
                </div>

                <main className="bg-gray-800 p-4 sm:p-6 rounded-2xl shadow-2xl border border-gray-700">
                   <h2 className="text-2xl font-bold text-white text-center mb-6">
                    {BENCHMARK_TITLES[selectedBenchmark]} Performance
                  </h2>
                  <div style={{ width: '100%', height: 500 }}>
                    <ResponsiveContainer>
                      <BarChart data={chartData} margin={{ top: 5, right: 20, left: 30, bottom: 5 }} barCategoryGap="20%">
                        <CartesianGrid strokeDasharray="3 3" stroke="#4a5568" />
                        <XAxis dataKey="name" angle={-45} textAnchor="end" height={120} tick={{ fill: '#a0aec0', fontSize: 12 }} interval={0} />
                        <YAxis tickFormatter={yAxisFormatter} tick={{ fill: '#a0aec0' }} label={{ value: 'Operations per Second (Higher is Better)', angle: -90, position: 'insideLeft', fill: '#cbd5e0', dy: 100 }} />
                        <Tooltip content={<CustomTooltip />} cursor={{fill: 'rgba(100, 116, 139, 0.1)'}} />
                        <Bar dataKey="ops" name="Ops/sec">
                           {chartData.map((entry, index) => <Cell key={\`cell-\${index}\`} fill={COLORS[entry.storage] || '#8884d8'} />)}
                        </Bar>
                        <Legend content={() => {
                            const uniquePayload = Object.keys(COLORS).map(key => ({ value: key, type: 'square', color: COLORS[key] }));
                            return (
                              <ul className="flex flex-wrap justify-center gap-x-6 gap-y-2 mt-4">
                                {uniquePayload.map((entry, index) => (
                                  <li key={\`item-\${index}\`} className="flex items-center">
                                    <div style={{width: 12, height: 12, backgroundColor: entry.color, marginRight: 8, borderRadius: '2px'}}></div>
                                    <span style={{ color: '#cbd5e0' }}>{entry.value}</span>
                                  </li>
                                ))}
                              </ul>
                            );
                          }}
                        />
                      </BarChart>
                    </ResponsiveContainer>
                  </div>
                </main>
              </div>
            </div>
          );
        }

        ReactDOM.render(<App />, document.getElementById('root'));
    </script>
</body>
</html>
EOF

echo "Chart generated successfully: $OUTPUT_FILE"
echo "You can now open this file in your web browser."
