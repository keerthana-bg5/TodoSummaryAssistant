pipeline {
    agent { label 'build-agent' }
    triggers { githubPush() }               // auto-start on push (plain Pipeline job)
    options  { timeout(time: 30, unit: 'MINUTES') }

    environment {
        DOCKERHUB_USER = 'keerthana2003bggowd'
        TAG            = "${env.GIT_COMMIT.take(7)}"          // image tag = commit SHA
        SSH_OPTS       = '-o StrictHostKeyChecking=no'
        HUB            = credentials('dockerhub-creds')       // gives HUB_USR / HUB_PSW
        KEY            = credentials('jenkins-agent-key')
        APP_HOST       = credentials('app-host')
        MON_HOST       = credentials('monitoring-host')
        APP_PRIVATE_IP = credentials('app-private-ip')
    }

    stages {
        stage('Checkout') {
            steps {
                git branch: 'main',
                credentialsId: 'github-pat',
                url: 'https://github.com/keerthana-bg5/TodoSummaryAssistant.git'
            }
        }
        stage('Test') {
            steps {
                dir('Backend/todo-summary-assistant') {
                    sh 'mvn -B clean verify'
                }
            }
        }
        stage('Build') {
            steps {
                sh 'docker build -t "$DOCKERHUB_USER/todo-backend:$TAG" Backend/todo-summary-assistant'
                sh 'docker build -t "$DOCKERHUB_USER/todo-frontend:$TAG" Frontend/todo'
            }
        }
        stage('Push') {
            steps {
                sh 'echo "$HUB_PSW" | docker login -u "$HUB_USR" --password-stdin'
                sh 'docker push "$DOCKERHUB_USER/todo-backend:$TAG"'
                sh 'docker push "$DOCKERHUB_USER/todo-frontend:$TAG"'
            }
        }
        stage('Deploy App') {
            when { branch 'main' }
            steps {
                sh 'scp $SSH_OPTS -i $KEY docker-compose.yml ubuntu@$APP_HOST:/opt/todo/'

                sh '''
                    ssh $SSH_OPTS -i $KEY ubuntu@$APP_HOST "
                        /snap/bin/aws ssm get-parameters-by-path \
                            --path /todo/prod/ \
                            --with-decryption \
                            --region ap-south-1 \
                            --query 'Parameters[*].[Name,Value]' \
                            --output text |
                        sed 's#/todo/prod/##; s#\\t#=#' > /opt/todo/.env
                    "
                '''

                sh 'ssh $SSH_OPTS -i $KEY ubuntu@$APP_HOST "cd /opt/todo && TAG=$TAG DOCKERHUB_USER=$DOCKERHUB_USER docker compose up -d"'
            }
        }
        stage('Health Check') {
            when { branch 'main' }
            steps {
                retry(10) {
                    sleep 10
                    sh 'curl -f http://$APP_HOST/'
                }
            }
        }
        stage('Deploy Monitoring') {
            when { branch 'main' }
            steps {
                sh '''
                    ssh $SSH_OPTS -i $KEY ubuntu@$MON_HOST "
                        cd /opt/todo/monitoring &&
                        GRAFANA_PASSWORD=\\$(/snap/bin/aws ssm get-parameter \
                            --name /todo/prod/grafana_password \
                            --with-decryption \
                            --query Parameter.Value \
                            --output text \
                            --region ap-south-1) \
                        docker compose up -d --force-recreate
                    "
                '''
            }
        }
    }
}