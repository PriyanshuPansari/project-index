#!/usr/bin/env bash

# Base directory for test projects
BASE_DIR="$HOME/test-projects"
mkdir -p "$BASE_DIR"

# Create Web App project
WEB_APP_DIR="$BASE_DIR/web-app"
mkdir -p "$WEB_APP_DIR/src"
touch "$WEB_APP_DIR/src/App.js"
touch "$WEB_APP_DIR/src/index.js"

cat > "$WEB_APP_DIR/.project.nix" << 'EOF'
{
  projectName = "React Web App";
  workspace = 2;
  tags = [ "frontend" "react" "web" ];
  environment = [
    {
      type = "browser";
      url = "http://localhost:3000";
      position = "left 50%";
    }
    {
      type = "terminal";
      command = "npm start";
      position = "bottom-right 25%";
    }
    {
      type = "editor";
      command = "nvim";
      files = [ "src/App.js" "src/index.js" ];
      position = "right 50%";
    }
  ];
}
EOF

# Create Backend API project
API_DIR="$BASE_DIR/api-service"
mkdir -p "$API_DIR/src"
touch "$API_DIR/src/server.js"
touch "$API_DIR/src/routes.js"

cat > "$API_DIR/.project.nix" << 'EOF'
{
  projectName = "Node.js API Service";
  workspace = 3;
  tags = [ "backend" "api" "nodejs" ];
  environment = [
    {
      type = "terminal";
      command = "npm run dev";
      position = "bottom 30%";
    }
    {
      type = "editor";
      command = "nvim";
      files = [ "src/server.js" "src/routes.js" ];
      position = "top 70%";
    }
    {
      type = "browser";
      url = "http://localhost:8080/api-docs";
      position = "right 30%";
    }
  ];
}
EOF

# Create Data Analysis project
DATA_DIR="$BASE_DIR/data-analysis"
mkdir -p "$DATA_DIR/notebooks"
touch "$DATA_DIR/notebooks/analysis.ipynb"

cat > "$DATA_DIR/.project.nix" << 'EOF'
{
  projectName = "Customer Data Analysis";
  workspace = 5;
  tags = [ "data" "analysis" "jupyter" ];
  environment = [
    {
      type = "terminal";
      command = "jupyter lab";
      position = "bottom-left 20%";
    }
    {
      type = "browser";
      url = "http://localhost:8888";
      position = "right 60%";
    }
    {
      type = "editor";
      command = "nvim";
      files = [ "data_processing.py" ];
      position = "left 40%";
    }
  ];
}
EOF

# Create Gaming project
GAME_DIR="$BASE_DIR/game-dev"
mkdir -p "$GAME_DIR/src"
touch "$GAME_DIR/src/main.cpp"

cat > "$GAME_DIR/.project.nix" << 'EOF'
{
  projectName = "2D Game Engine";
  workspace = 7;
  tags = [ "game" "cpp" "engine" ];
  environment = [
    {
      type = "terminal";
      command = "make && ./build/game";
      position = "bottom 25%";
    }
    {
      type = "editor";
      command = "nvim";
      files = [ "src/main.cpp" "src/engine.h" ];
      position = "left 75%";
    }
  ];
}
EOF

echo "Created test projects in $BASE_DIR:"
ls -la "$BASE_DIR"
echo ""
echo "To test with these projects, update the PROJECT_DIRS in the script to include:"
echo "PROJECT_DIRS=(\"$BASE_DIR\")"
